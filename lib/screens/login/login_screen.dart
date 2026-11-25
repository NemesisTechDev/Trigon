import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/services.dart'
    show AutofillHints, SystemNavigator, TextInput;
import '../../services/account_store.dart';
import '../../services/jellyfin_services/auth_service.dart';
import '../../services/jellyfin_services/jellyfin_client.dart';
import '../../services/jellyfin_services/storage_service.dart';
import '../../services/sync/cloud_sync_service.dart';
import '../../utils/responsive.dart';
import '../../widgets/auth/floating_label_field.dart';
import '../../widgets/auth/auth_background.dart';
import '../../widgets/auth/breathing_logo.dart';
import '../../widgets/auth/premium_gold_button.dart';
import '../../widgets/auth/staggered_entrance.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final usernameController = TextEditingController();
  final passwordController = TextEditingController();

  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();

  bool loading = false;
  String? error;
  // Friendly (non-error) message, e.g. "verification email sent".
  String? info;
  bool _googleLoading = false;
  // Shown after a sign-in is refused because the email isn't verified yet.
  bool _showResend = false;
  bool _obscurePassword = true;

  // Tracks whether this screen already told the platform's Autofill
  // framework (device password manager) whether to save the entered
  // credentials, so dispose()'s safety-net call below doesn't fire a
  // second, contradictory finishAutofillContext(shouldSave: false)
  // right after a successful login already committed
  // shouldSave: true.
  bool _autofillFinished = false;

  // Picking a saved email/password from the device's autofill list fills the
  // fields in one go (a jump of several characters, where typing adds one at
  // a time). That is how the screen notices a saved login was picked and
  // signs in by itself. See _onCredentialsChanged.
  int _prevPasswordLength = 0;
  Timer? _autoSignInTimer;

  // Guards _handleBackPressed against a second gesture/press firing
  // while the first disconnect is still in flight (StorageService +
  // JellyfinClient.refresh below are both awaited, so there's a real
  // window where a second back gesture could otherwise re-enter this
  // and double up the navigation).
  bool _disconnecting = false;

  // Guards against a second back gesture re-opening the confirmation
  // dialog on top of itself while it's already showing (PopScope's
  // onPopInvoked fires again on every subsequent back press/gesture).
  bool _confirmingDisconnect = false;

  // Toggles the whole screen between its Sign In and Sign Up copy.
  // Sign Up itself isn't wired to a real backend flow yet — see
  // _createAccountPlaceholder() below — so this only flips presentation.
  bool _isSignUp = false;

  final _termsRecognizer = TapGestureRecognizer();
  final _switchModeRecognizer = TapGestureRecognizer();
  final _forgotPasswordRecognizer = TapGestureRecognizer();

  static const Color gold = Color(0xFFD4AF37);

  late final AnimationController _entrance;

  @override
  void initState() {
    super.initState();
    // Set when a profile switch found that profile's session expired.
    usernameController.text = AccountStore.takePendingLoginUsername() ?? '';
    _prevPasswordLength = passwordController.text.length;
    passwordController.addListener(_onCredentialsChanged);
    _termsRecognizer.onTap = _openTermsPlaceholder;
    _switchModeRecognizer.onTap = _toggleSignUp;
    _forgotPasswordRecognizer.onTap = _forgotPassword;
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..forward();
  }

  /// Signs in by itself when a saved login was picked from the autofill
  /// list. The password field is filled in one step (several characters at
  /// once, never by typing one key), and the email is already there. Only on
  /// Sign In (never Sign Up, where the password is a new one), and a short
  /// wait lets the email finish filling first.
  void _onCredentialsChanged() {
    final length = passwordController.text.length;
    final jumped = length - _prevPasswordLength > 1;
    _prevPasswordLength = length;
    if (!jumped || _isSignUp || loading || _googleLoading) return;

    _autoSignInTimer?.cancel();
    _autoSignInTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || _isSignUp || loading || _googleLoading) return;
      if (usernameController.text.trim().isEmpty ||
          passwordController.text.isEmpty) {
        return;
      }
      login();
    });
  }

  @override
  void dispose() {
    _autoSignInTimer?.cancel();
    passwordController.removeListener(_onCredentialsChanged);
    // Safety net for anyone leaving this screen without ever reaching
    // a successful login (back gesture, app backgrounded mid-entry,
    // etc.) — tells the autofill service not to prompt/save whatever
    // was typed. A no-op if no autofill session is active, and
    // skipped entirely when login() already resolved this explicitly
    // (see _autofillFinished above).
    if (!_autofillFinished) {
      TextInput.finishAutofillContext(shouldSave: false);
    }
    _entrance.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    usernameController.dispose();
    passwordController.dispose();
    _termsRecognizer.dispose();
    _switchModeRecognizer.dispose();
    _forgotPasswordRecognizer.dispose();
    super.dispose();
  }

  // --- Functionality below is unchanged from the original screen. ---

  /// Replaces the whole navigation stack with Home. `pushNamed...RemoveUntil`
  /// (not a plain replacement) so no stale "/login" or "/setup" route is
  /// left underneath Home - otherwise a back press at the Home tab could
  /// pop down to it instead of reaching the exit-confirmation dialog.
  void _goHome() {
    Navigator.of(context).pushNamedAndRemoveUntil("/home", (route) => false);
  }

  void _resetMessages() {
    error = null;
    info = null;
    _showResend = false;
  }

  Future<void> login() async {
    if (loading || _googleLoading) return;
    FocusScope.of(context).unfocus();
    setState(() {
      loading = true;
      _resetMessages();
    });

    final result = await AuthService.login(
      email: usernameController.text,
      password: passwordController.text,
    );

    if (!mounted) return;
    setState(() => loading = false);

    if (result.success) {
      // Commits the just-entered email/password to the OS Autofill
      // framework (Google Password Manager etc.), which is what shows the
      // "Save password?" prompt. Nemesis itself never stores the password.
      // Must run before dispose() reads _autofillFinished.
      TextInput.finishAutofillContext(shouldSave: true);
      _autofillFinished = true;
      await _offerGuestImport();
      if (!mounted) return;
      _goHome();
      return;
    }

    setState(() {
      error = result.message;
      _showResend = result.errorType == AuthErrorType.emailNotVerified;
    });
  }

  Future<void> _signUp() async {
    if (loading || _googleLoading) return;
    FocusScope.of(context).unfocus();
    setState(() {
      loading = true;
      _resetMessages();
    });

    final result = await AuthService.signUp(
      email: usernameController.text,
      password: passwordController.text,
    );

    if (!mounted) return;
    setState(() => loading = false);

    if (result.isPending) {
      // Account exists but can't be used until the email is verified, so
      // go back to Sign In and say so.
      setState(() {
        _isSignUp = false;
        info = result.message;
        passwordController.clear();
      });
      return;
    }

    setState(() {
      error = result.message;
      _showResend = result.errorType == AuthErrorType.emailNotVerified;
    });
  }

  Future<void> _google() async {
    if (loading || _googleLoading) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _googleLoading = true;
      _resetMessages();
    });

    final result = await AuthService.signInWithGoogle();

    if (!mounted) return;
    setState(() => _googleLoading = false);

    if (result.success) {
      await _offerGuestImport();
      if (!mounted) return;
      _goHome();
      return;
    }
    // Dismissing the Google chooser isn't an error worth showing.
    if (result.errorType == AuthErrorType.cancelled) return;
    setState(() => error = result.message);
  }

  Future<void> _forgotPassword() async {
    if (loading || _googleLoading) return;
    final email = usernameController.text.trim();
    if (email.isEmpty) {
      setState(() {
        _resetMessages();
        error = 'Enter your email above, then tap "Forgot your password?".';
      });
      return;
    }

    setState(_resetMessages);
    final result = await AuthService.sendPasswordReset(email);
    if (!mounted) return;
    setState(() {
      if (result.success) {
        info = result.message;
      } else {
        error = result.message;
      }
    });
  }

  Future<void> _resendVerification() async {
    if (loading || _googleLoading) return;
    setState(() {
      loading = true;
      error = null;
      info = null;
    });
    final result = await AuthService.resendVerification(
      email: usernameController.text,
      password: passwordController.text,
    );
    if (!mounted) return;
    setState(() {
      loading = false;
      if (result.success) {
        info = result.message;
        _showResend = false;
      } else {
        error = result.message;
      }
    });
  }

  /// Same confirm/cancel dialog as ProfileSettingsScreen's "Disconnect
  /// Server" action — same title, message, and destructive-red
  /// "Disconnect" styling — just shown ahead of the back-gesture flow
  /// here instead of a menu tap.
  Future<bool> _confirmDisconnect() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xff1A1A1A),
        title: const Text(
          "Disconnect Server",
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          "You'll be signed out and the connected server will be "
          "forgotten. You'll need to enter a server address again to "
          "sign back in.",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text(
              "Cancel",
              style: TextStyle(color: Colors.white54),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(
              "Disconnect",
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  /// Backs out of the login screen via the phone's back gesture/button
  /// straight into server setup — same "forget this server" flow as
  /// ProfileSettingsScreen's "Disconnect Server" action (logoutServer +
  /// JellyfinClient.refresh), just triggered by the back gesture here
  /// instead of a menu tap, since there's no server-configured account
  /// to just sign out of at this screen the way _logOutUser has. A
  /// confirm/cancel dialog (matching ProfileSettingsScreen's own) is
  /// shown first — the actual disconnect only proceeds if the user
  /// taps "Disconnect"; a cancel or dismiss just closes the dialog and
  /// leaves this screen exactly as it was. The snackbar is shown first
  /// and awaited-around rather than fired and forgotten, so it's
  /// actually visible for a beat before pushNamedAndRemoveUntil tears
  /// this screen down under it.
  Future<void> _handleBackPressed() async {
    if (_disconnecting || _confirmingDisconnect) return;

    // Coming from Setup, Setup is still sitting on the stack right
    // below this route (setup_screen.dart's save() pushes "/login" with
    // a plain pushNamed, deliberately leaving it there — see its own
    // comment). There's nothing to disconnect yet in that case: no
    // login has happened, the server address is just sitting there
    // ready to be edited, so back should be a plain pop straight to
    // it — no confirmation dialog, no logoutServer/JellyfinClient
    // .refresh disconnect flow.
    //
    // Coming from a logout (ProfileSettingsScreen._logOutUser),
    // "/login" was pushed with pushNamedAndRemoveUntil((route) =>
    // false), which clears every route below it — including Setup —
    // so this is the sole route left and canPop() is false. That's
    // the real "forget this server" case the confirmation dialog and
    // disconnect flow below exist for, and it's unchanged.
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }

    // NAMESIS PRIME: there is no server setup screen to go back to, so back
    // from the login screen just leaves the app.
    SystemNavigator.pop();
    return;
    // ignore: dead_code
    setState(() => _confirmingDisconnect = true);
    final confirmed = await _confirmDisconnect();
    if (!mounted) return;
    setState(() => _confirmingDisconnect = false);

    if (!confirmed) return;

    setState(() => _disconnecting = true);

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text("Disconnecting from server..."),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Color(0xff1A1A1A),
        ),
      );

    await StorageService.logoutServer();
    await JellyfinClient.refresh();

    if (!mounted) return;

    // rootNavigator + removeUntil(false): same reasoning as login()'s
    // own post-sign-in navigation above — this needs to clear
    // whatever's already in the stack (this "/login" route itself,
    // and a leftover "/setup" beneath it when that's how this screen
    // was reached) rather than just pushing another route on top of
    // it, or the back gesture would land right back here.
    Navigator.of(context, rootNavigator: true)
        .pushNamedAndRemoveUntil("/setup", (route) => false);
  }

  // --- Placeholder UI only: the Terms link and guest mode have no
  // backing feature yet. Each just surfaces a lightweight "not ready yet"
  // acknowledgment so the UI doesn't feel dead, without pretending the
  // feature works. ---

  void _placeholder(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xff1A1A1A),
        ),
      );
  }

  void _openTermsPlaceholder() => _placeholder("Terms of Service page is coming soon.");

  /// Guest mode: opens the app with everything stored on this device only.
  /// Nothing is read from or written to any account.
  Future<void> _continueWithoutAccount() async {
    if (loading || _googleLoading) return;
    FocusScope.of(context).unfocus();
    setState(() {
      loading = true;
      _resetMessages();
    });
    try {
      await AuthService.startGuestSession();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = 'Couldn\'t start guest mode. Please try again.';
      });
      return;
    }
    if (!mounted) return;
    setState(() => loading = false);
    _goHome();
  }

  /// Right after signing in: if this device holds data from guest mode,
  /// ask whether to add it to the account. Declining keeps it on the device
  /// (it comes back when signed out) and never uploads it.
  Future<void> _offerGuestImport() async {
    if (!CloudSync.instance.hasGuestStash || !mounted) return;
    final add = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xff1A1A1A),
        title: const Text(
          "Add guest data to your account?",
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          "This device has watch history, favorites and settings saved from "
          "guest mode. Add them to your account so they follow you to your "
          "other devices?",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text(
              "Not now",
              style: TextStyle(color: Colors.white54),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(
              "Add to account",
              style: TextStyle(color: gold, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    if (add == true) {
      try {
        await CloudSync.instance.importGuestData();
      } catch (_) {}
    }
  }

  void _toggleSignUp() {
    setState(() {
      _isSignUp = !_isSignUp;
      _resetMessages();
    });
  }

  // --- UI below is a visual redesign matching the new design concept. ---

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Same "intercept every back event and decide for ourselves"
      // pattern MainNavScreen's own PopScope uses — canPop: false
      // means the framework never pops this route on its own, so
      // _handleBackPressed is free to run the disconnect flow first
      // and drive the navigation itself once that's done, instead of
      // the screen popping immediately (straight back to a stale
      // "/setup" underneath, with the server never actually forgotten)
      // and racing it.
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        _handleBackPressed();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: AuthBackground(
        // Was SafeArea here. SafeArea's own build() calls the
        // *unscoped* MediaQuery.of(context) internally, which
        // subscribes it to every MediaQueryData field — including
        // viewInsets.bottom, which the framework updates on every
        // single frame while the keyboard (username/server-address
        // field) is sliding open or closed. Each of those frames forced
        // this entire form — including the StaggeredEntrance-animated
        // logo/heading — to rebuild in lockstep with the keyboard's own
        // animation instead of just letting the already-scrollable
        // SingleChildScrollView shift underneath it. A plain Padding
        // using the aspect-scoped `MediaQuery.paddingOf` below gets the
        // identical safe-area values but only rebuilds when device
        // padding itself actually changes — same fix as Music/Movies/
        // Live TV/Downloads/Search/Home.
        child: SingleChildScrollView(
              // The safe-area insets are part of the scroll view's own padding (not
              // an outer Padding), so the content scrolls all the way up to the top
              // edge of the display, behind the status bar, like the home screen.
              padding: EdgeInsets.fromLTRB(
                24 + MediaQuery.paddingOf(context).left,
                16 + MediaQuery.paddingOf(context).top,
                24 + MediaQuery.paddingOf(context).right,
                16 + MediaQuery.paddingOf(context).bottom,
              ),
              // Constrains the form to a sane max width on tablet/TV so the
              // username/password fields and Sign In button don't stretch
              // edge-to-edge at 1920-3840px; unchanged on phone, where
              // constrainedContentWidth's clamp never engages. Centered
              // via the outer Center, same pattern as Profile's settings
              // screens and setup_screen.dart.
              child: Center(
                child: ConstrainedBox(
                  key: const ValueKey('login_form_constraint'),
                  constraints: BoxConstraints(
                    maxWidth:
                        Responsive.constrainedContentWidth(context, maxWidth: 440),
                  ),
                  child: Column(
                children: [
                  // Logo on the left, brand name on the right (same layout as the
                  // top-left of the home screen), centered on the screen.
                  StaggeredEntrance(
                    controller: _entrance,
                    start: 0.0,
                    end: 0.6,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        BreathingLogo(size: 52),
                        SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            "Trigon",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: gold,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 28),

                  StaggeredEntrance(
                    controller: _entrance,
                    start: 0.2,
                    end: 0.75,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: Text(
                        _isSignUp ? "Create Account" : "Welcome Back",
                        key: ValueKey(_isSignUp),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 6),

                  StaggeredEntrance(
                    controller: _entrance,
                    start: 0.24,
                    end: 0.8,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: Text(
                        _isSignUp
                            ? "Sign up to sync your data across devices"
                            : "Sign in to continue",
                        key: ValueKey(_isSignUp),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 22),

                  // The email/password fields are NOT part of the staggered
                  // entrance any more. They used to fade in over the first
                  // ~0.8 s (and start fully transparent), and Android's
                  // saved-password suggestion only appeared once they had
                  // settled, which read as a slow "saved password". Drawn
                  // fully opaque from the first frame, the suggestion
                  // shows as soon as the field is tapped. (Same
                  // AutofillGroup as before: both fields stay one form.)
                  AutofillGroup(
                      child: Column(
                      children: [
                        FloatingLabelField(
                          label: "Email",
                          controller: usernameController,
                          focusNode: _usernameFocus,
                          keyboardType: TextInputType.emailAddress,
                          prefixIcon: Icons.mail_outline,
                          floating: false,
                          // Sign In offers saved logins on THIS field too:
                          // asking for both username and email is what
                          // makes the device list them here and not only
                          // on the password field.
                          autofillHints: _isSignUp
                              ? const [AutofillHints.email]
                              : const [
                                  AutofillHints.username,
                                  AutofillHints.email,
                                ],
                        ),

                        const SizedBox(height: 16),

                        FloatingLabelField(
                          label: "Password",
                          controller: passwordController,
                          focusNode: _passwordFocus,
                          obscureText: _obscurePassword,
                          prefixIcon: Icons.lock_outline,
                          floating: false,
                          autofillHints: _isSignUp
                              ? const [AutofillHints.newPassword]
                              : const [AutofillHints.password],
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              color: Colors.white.withValues(alpha: 0.4),
                              size: 20,
                            ),
                            onPressed: () {
                              setState(() => _obscurePassword = !_obscurePassword);
                            },
                          ),
                        ),

                        AnimatedSize(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                          child: _isSignUp
                              ? Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      "At least 8 characters, with a letter and a number.",
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.45),
                                        fontSize: 12.5,
                                      ),
                                    ),
                                  ),
                                )
                              : Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: GestureDetector(
                                      onTap: _forgotPassword,
                                      child: Text(
                                        "Forgot your password?",
                                        style: TextStyle(
                                          color: gold,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                        ),

                        AnimatedSize(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                          child: error == null
                              ? const SizedBox(width: double.infinity)
                              : Padding(
                                  padding: const EdgeInsets.only(top: 16),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.error_outline,
                                          color: Colors.redAccent, size: 18),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          error!,
                                          style: const TextStyle(color: Colors.redAccent),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                        ),

                        AnimatedSize(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                          child: info == null
                              ? const SizedBox(width: double.infinity)
                              : Padding(
                                  padding: const EdgeInsets.only(top: 16),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Icon(Icons.mark_email_read_outlined,
                                          color: gold, size: 18),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          info!,
                                          style: TextStyle(
                                            color: Colors.white.withValues(alpha: 0.85),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                        ),

                        AnimatedSize(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                          child: !_showResend
                              ? const SizedBox(width: double.infinity)
                              : Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: GestureDetector(
                                      onTap: _resendVerification,
                                      child: const Text(
                                        "Resend verification email",
                                        style: TextStyle(
                                          color: gold,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                        ),

                        AnimatedSize(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                          child: !_isSignUp
                              ? const SizedBox(width: double.infinity)
                              : Padding(
                                  padding: const EdgeInsets.only(top: 20),
                                  child: _buildTermsNotice(),
                                ),
                        ),

                        const SizedBox(height: 20),

                        _isSignUp ? _buildCreateAccountButton() : _buildSignInButton(),

                        const SizedBox(height: 16),

                        _buildSwitchModeRow(),
                      ],
                    ),
                    ),

                  const SizedBox(height: 22),

                  StaggeredEntrance(
                    controller: _entrance,
                    start: 0.4,
                    end: 1.0,
                    child: Column(
                      children: [
                        _buildOrDivider(),
                        const SizedBox(height: 16),
                        _buildGoogleButton(),
                        const SizedBox(height: 12),
                        _buildContinueWithoutAccountButton(),
                        const SizedBox(height: 12),
                        Text(
                          "Your data will only be stored locally",
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
                ),
              ),
          ),
      ),
      ),
    );
  }

  Widget _buildSignInButton() {
    return PremiumGoldButton(
      onTap: login,
      loading: loading,
      child: loading
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                color: Colors.black,
                strokeWidth: 2.4,
              ),
            )
          : const Text(
              "Sign In",
              style: TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
    );
  }

  Widget _buildCreateAccountButton() {
    return PremiumGoldButton(
      onTap: _signUp,
      loading: loading,
      child: loading
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                color: Colors.black,
                strokeWidth: 2.4,
              ),
            )
          : const Text(
              "Create Account",
              style: TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
    );
  }

  Widget _buildTermsNotice() {
    return RichText(
      textAlign: TextAlign.center,
      text: TextSpan(
        style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 13),
        children: [
          const TextSpan(text: "By signing up I agree to the "),
          TextSpan(
            text: "Terms",
            style: const TextStyle(
              color: gold,
              fontWeight: FontWeight.w600,
            ),
            recognizer: _termsRecognizer,
          ),
        ],
      ),
    );
  }

  Widget _buildSwitchModeRow() {
    return RichText(
      textAlign: TextAlign.center,
      text: TextSpan(
        style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 13.5),
        children: [
          TextSpan(text: _isSignUp ? "Already have an account? " : "Don't have an account? "),
          TextSpan(
            text: _isSignUp ? "Sign in" : "Sign Up",
            style: const TextStyle(color: gold, fontWeight: FontWeight.w700),
            recognizer: _switchModeRecognizer,
          ),
        ],
      ),
    );
  }

  Widget _buildOrDivider() {
    return Row(
      children: [
        Expanded(
          child: Divider(color: Colors.white.withValues(alpha: 0.14), thickness: 1),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            "or",
            style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 13),
          ),
        ),
        Expanded(
          child: Divider(color: Colors.white.withValues(alpha: 0.14), thickness: 1),
        ),
      ],
    );
  }

  Widget _buildGoogleButton() {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: (loading || _googleLoading) ? null : _google,
          child: Center(
            child: _googleLoading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      color: Colors.black,
                      strokeWidth: 2.4,
                    ),
                  )
                : const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _GoogleGlyph(),
                      SizedBox(width: 12),
                      Text(
                        "Continue with Google",
                        style: TextStyle(
                          color: Colors.black87,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildContinueWithoutAccountButton() {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: Material(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _continueWithoutAccount,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            ),
            alignment: Alignment.center,
            child: const Text(
              "Continue Without Account",
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Google's official multicolour "G" (the standard sign-in button mark,
/// 48 x 48 viewBox), drawn from embedded SVG so it needs no asset file.
class _GoogleGlyph extends StatelessWidget {
  const _GoogleGlyph();

  static const String _svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
  <path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/>
  <path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/>
  <path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/>
  <path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/>
</svg>
''';

  @override
  Widget build(BuildContext context) {
    return SvgPicture.string(_svg, width: 22, height: 22);
  }
}
