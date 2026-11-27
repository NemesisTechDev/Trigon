import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../utils/responsive.dart';
import '../../utils/bottom_clearance.dart';
import '../../services/jellyfin_services/auth_service.dart';
import '../../services/jellyfin_services/jellyfin_client.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../services/jellyfin_services/storage_service.dart';
import '../../widgets/common/collapsing_screen_label.dart';
import '../../widgets/common/keyboard_safe_dialog.dart';
import '../../widgets/common/pressable.dart';
import 'app_settings_screen.dart';
import '../addons/addons_screen.dart';
import '../../widgets/common/dustbin_icon.dart';
import '../../services/account_store.dart';
import '../../services/parental/parental_controls.dart';
import '../../widgets/profile/switch_profile_sheet.dart';
import '../../widgets/profile/profile_avatar.dart';
import 'edit_profile_screen.dart';
import '../../services/profile_avatar_service.dart';

/// Whether Profile & Settings shows the Addons entry. Hidden for now; flip
/// to true to bring it back.
const bool _kShowAddonsSetting = false;

const _gold = Color(0xffD4AF37);
const _bg = Color(0xff161616);
const _cardBg = Color(0xff1F1F1F);

class ProfileSettingsScreen extends StatefulWidget {
  const ProfileSettingsScreen({super.key});

  @override
  State<ProfileSettingsScreen> createState() => _ProfileSettingsScreenState();
}

class _ProfileSettingsScreenState extends State<ProfileSettingsScreen> {
  String? _username;
  String? _serverUrl;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final username = await StorageService.getUsername();
    final serverUrl = await StorageService.getServerUrl();
    if (!mounted) return;
    setState(() {
      _username = username;
      // Shows the account email (falls back to the old value if somehow
      // signed out). The field keeps its old name to avoid touching the UI.
      _serverUrl = AuthService.currentEmail ?? serverUrl;
    });
  }

  /// Opens the Edit Profile page (name + avatar) and, when it closes,
  /// re-reads the saved name so this screen shows the new one.
  Future<void> _openEditProfile() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const EditProfileScreen()),
    );
    if (mounted) _load();
  }

  /// Signs out of the current user only — the server stays configured,
  /// so the person lands back on the login screen for the same server.
  Future<void> _logOutUser() async {
    // Parental Controls: signing out drops into an unrestricted-looking
    // guest session, so a parent must approve it.
    if (!await ParentalControls.instance.guardAccountAction(context, 'Log out')) {
      return;
    }
    if (!mounted) return;
    final confirmed = await _confirm(
      title: "Log Out",
      message: "You'll be signed out of this account. You can sign back "
          "in any time.",
      confirmLabel: "Log Out",
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    // Signing out must also forget this profile's saved quick-switch
    // token, or "Log Out" would leave a working credential behind.
    // The two slow, independent steps run side by side (forgetting the saved
    // token is Keystore work; sign-out is sync + auth work) instead of one
    // after the other. Both ids are read first, before anything changes.
    final userId = JellyfinClient.userId;
    final serverUrl = JellyfinClient.serverUrl;
    await Future.wait([
      AccountStore.remove(userId, serverUrl),
      AuthService.signOut(),
    ]);
    await StorageService.logoutUser();
    await JellyfinClient.refresh();
    if (!mounted) return;

    Navigator.of(context, rootNavigator: true)
        .pushNamedAndRemoveUntil("/login", (route) => false);
  }

  /// Clears the server address too, sending the person all the way back
  /// through server setup — used to switch to a different Jellyfin
  /// server entirely.
  Future<void> _disconnectServer() async {
    final confirmed = await _confirm(
      title: "Disconnect Server",
      message: "You'll be signed out and the connected server will be "
          "forgotten. You'll have to enter the server address again to "
          "sign back in.",
      confirmLabel: "Disconnect",
      destructive: true,
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    await AccountStore.removeAllForServer(JellyfinClient.serverUrl);
    await AuthService.signOut();
    await StorageService.logoutServer();
    await JellyfinClient.refresh();
    if (!mounted) return;

    Navigator.of(context, rootNavigator: true)
        .pushNamedAndRemoveUntil("/setup", (route) => false);
  }

  /// Permanently deletes the signed-in account. Two gates before anything
  /// destructive happens: an explicit "yes I understand this is permanent"
  /// confirmation, then re-confirmation of identity - the password for
  /// email accounts (checked by Firebase itself, not against anything cached
  /// on this device) or a fresh Google prompt for Google accounts - so this
  /// can't be triggered by someone who just picked up an unlocked device.
  Future<void> _deleteAccount() async {
    if (!await ParentalControls.instance
        .guardAccountAction(context, 'Delete account')) {
      return;
    }
    if (!mounted) return;
    final confirmedIntent = await _confirm(
      title: "Delete Account",
      message: "This permanently deletes your account and everything tied "
          "to it including watch history, favorites, personal settings. "
          "This can't be undone.",
      confirmLabel: "Continue",
      destructive: true,
    );
    if (confirmedIntent != true) return;

    String? password;
    if (AuthService.usesPasswordSignIn) {
      password = await _promptPasswordForDeletion();
      if (password == null || password.isEmpty) return;
    }

    if (!mounted) return;
    setState(() => _busy = true);

    final result = await AuthService.deleteAccount(password: password);

    if (!mounted) return;

    if (!result.success) {
      setState(() => _busy = false);
      // Backing out of the Google prompt is not an error.
      if (result.errorType == AuthErrorType.cancelled) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.errorType == AuthErrorType.invalidCredentials
                ? "Incorrect password. Account not deleted."
                : result.message,
          ),
        ),
      );
      return;
    }

    await AccountStore.remove(JellyfinClient.userId, JellyfinClient.serverUrl);
    await StorageService.logoutUser();
    await JellyfinClient.refresh();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true)
        .pushNamedAndRemoveUntil("/login", (route) => false);
  }

  /// Small password-only dialog used just before deleting the account.
  /// Returns the entered password, or null if the person backed out.
  /// Validation of the password itself happens back in [_deleteAccount]
  /// (by Firebase) — this dialog only makes sure something
  /// was actually typed before handing it back.
  Future<String?> _promptPasswordForDeletion() {
    final controller = TextEditingController();
    bool obscure = true;
    String? errorText;

    return showDialog<String>(
      context: context,
      builder: (dialogContext) => KeyboardSafeDialog(
        child: StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          void submit() {
            if (controller.text.isEmpty) {
              setDialogState(() => errorText = "Password required");
              return;
            }
            Navigator.pop(dialogContext, controller.text);
          }

          return AlertDialog(
            alignment: keyboardSafeDialogAlignment,
            backgroundColor: _cardBg,
            title: const Text(
              "Confirm Your Password",
              style: TextStyle(color: Colors.white),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Enter your password to confirm it's really you deleting "
                  "this account.",
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  obscureText: obscure,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  onChanged: (_) {
                    if (errorText != null) {
                      setDialogState(() => errorText = null);
                    }
                  },
                  onSubmitted: (_) => submit(),
                  decoration: InputDecoration(
                    hintText: "Password",
                    hintStyle: const TextStyle(color: Colors.white38),
                    errorText: errorText,
                    enabledBorder: const UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: const UnderlineInputBorder(
                      borderSide: BorderSide(color: _gold),
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscure ? Icons.visibility_off : Icons.visibility,
                        color: Colors.white38,
                        size: 20,
                      ),
                      onPressed: () =>
                          setDialogState(() => obscure = !obscure),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, null),
                child: const Text(
                  "Cancel",
                  style: TextStyle(color: Colors.white54),
                ),
              ),
              TextButton(
                onPressed: submit,
                child: const Text(
                  "Confirm",
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          );
        },
        ),
      ),
    );
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _cardBg,
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(
          message,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel", style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              confirmLabel,
              style: TextStyle(
                color: destructive ? Colors.redAccent : _gold,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userId = JellyfinClient.userId;
    final avatarUrl =
        userId.isNotEmpty ? MediaService.getUserImageUrl(userId, maxWidth: 200) : null;

    // LabelCollapseScope: the "Profile & Settings" app bar slides away on
    // scroll down and returns on scroll up (see
    // collapsing_screen_label.dart).
    return LabelCollapseScope(
      child: Scaffold(
      backgroundColor: _bg,
      // primary: false — CollapsibleAppBar supplies the status-bar inset
      // itself so the bar can collapse down to just that inset.
      appBar: CollapsibleAppBar(
        child: AppBar(
          primary: false,
          backgroundColor: _bg,
          title: const Text("Profile & Settings", style: TextStyle(color: Colors.white)),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(child: AbsorbPointer(
        absorbing: _busy,
        // A settings form stretched edge-to-edge on a tablet/TV-wide
        // viewport reads as an unfinished layout rather than a
        // deliberate one — capped to a comfortable reading/form width
        // and centered, same as this screen's own avatar block already
        // centers itself. On phones availableContentWidth is already
        // below 700, so this SizedBox just gets the full width it
        // always had — the Pixel 6 layout is unchanged.
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: Responsive.constrainedContentWidth(context, maxWidth: 700),
            // BottomClearanceBuilder so the form's trailing padding
            // reactively clears the main nav's floating bottom bar
            // (mini player + tab bar in portrait) — MainNavScreen
            // paints that bar in a plain Stack, not a real
            // Scaffold.extendBody (see its own doc comment for why),
            // so nothing here happens automatically the way SafeArea
            // would for a system inset.
            child: BottomClearanceBuilder(
              builder: (context, bottomClearance) => ListView(
              padding: EdgeInsets.fromLTRB(
                20, 24, 20,
                40 + MediaQuery.paddingOf(context).bottom + bottomClearance,
              ),
              children: [
                Center(
                  child: Column(
                    children: [
                      // Tapping the picture opens the Edit Profile page.
                      ListenableBuilder(
                        listenable: ProfileAvatarService.instance,
                        builder: (context, _) {
                          final canChoose =
                              ProfileAvatarService.instance.canChoose;
                          return GestureDetector(
                            onTap: canChoose ? _openEditProfile : null,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Container(
                                  width: 96,
                                  height: 96,
                                  clipBehavior: Clip.antiAlias,
                                  decoration: const BoxDecoration(
                                    color: Colors.black45,
                                    shape: BoxShape.circle,
                                  ),
                                  child: ProfileAvatarBody(
                                    fallback: avatarUrl == null
                                        ? const Icon(Icons.person_outline,
                                            color: Colors.white, size: 44)
                                        : CachedNetworkImage(
                                            imageUrl: avatarUrl,
                                            fit: BoxFit.cover,
                                            placeholder: (context, url) =>
                                                const Icon(
                                              Icons.person_outline,
                                              color: Colors.white,
                                              size: 44,
                                            ),
                                            errorWidget:
                                                (context, url, error) =>
                                                    const Icon(
                                              Icons.person_outline,
                                              color: Colors.white,
                                              size: 44,
                                            ),
                                          ),
                                  ),
                                ),
                                if (canChoose)
                                  Positioned(
                                    right: -2,
                                    bottom: -2,
                                    child: Container(
                                      width: 32,
                                      height: 32,
                                      decoration: BoxDecoration(
                                        color: const Color(0xffD4AF37),
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                            color: _bg, width: 2.5),
                                      ),
                                      child: const Icon(Icons.edit_rounded,
                                          color: Colors.black, size: 16),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                  const SizedBox(height: 16),
                  Text(
                    _username ?? "—",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _serverUrl ?? "",
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 36),
            _sectionLabel("Account"),
            const SizedBox(height: 10),
            ListenableBuilder(
              listenable: ProfileAvatarService.instance,
              builder: (context, _) {
                if (!ProfileAvatarService.instance.canChoose) {
                  return const SizedBox.shrink();
                }
                return Column(
                  children: [
                    _settingsTile(
                      icon: Icons.edit_outlined,
                      label: "Edit profile",
                      subtitle: "Change your username and avatar",
                      onTap: _openEditProfile,
                    ),
                    const SizedBox(height: 10),
                  ],
                );
              },
            ),
            _settingsTile(
              icon: Icons.swap_horiz_rounded,
              label: "Switch Profile",
              subtitle: "Switch to another profile",
              onTap: () => SwitchProfileSheet.show(context),
            ),
            const SizedBox(height: 10),
            _settingsTile(
              icon: Icons.logout,
              label: "Log Out",
              subtitle: "Sign out of this account",
              onTap: _logOutUser,
            ),
            const SizedBox(height: 10),
            _settingsTile(
              customIcon: const DustbinIcon(size: 22, color: Colors.redAccent),
              label: "Delete Account",
              subtitle: "Permanently delete your account",
              onTap: _deleteAccount,
              destructive: true,
            ),
            const SizedBox(height: 24),
            _sectionLabel("App"),
            const SizedBox(height: 10),
            _settingsTile(
              icon: Icons.settings_outlined,
              label: "Settings",
              subtitle: "Playback, sources, downloads, and parental controls",
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AppSettingsScreen(),
                  ),
                );
              },
            ),
            // NAMESIS PRIME: the Addons entry is hidden while a default addon is
            // installed automatically (see addons/default_addons.dart). Set
            // [_kShowAddonsSetting] to true to show it again; nothing else
            // about it was removed.
            if (_kShowAddonsSetting) ...[
              const SizedBox(height: 24),
              // There is no server to disconnect from. This is where the
              // person installs the addon that provides streams.
              _sectionLabel("Addons"),
              const SizedBox(height: 10),
              _settingsTile(
                icon: Icons.extension_outlined,
                label: "Addons",
                subtitle: "Install and manage your stream addon",
                onTap: () async {
                  if (!await ParentalControls.instance.guardAddons(context)) {
                    return;
                  }
                  if (!context.mounted) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const AddonsScreen(),
                    ),
                  );
                },
              ),
            ],
            // Branding footer: the same logo + gold name as the top-left of
            // Home, centered, with the maker's credit underneath. It is the
            // last item of this ListView, whose bottom padding already
            // includes the main nav's clearance, so scrolling to the end
            // leaves it fully above the mini player / tab bar.
            const SizedBox(height: 40),
            _brandingFooter(),
              ],
            ),
            ),
          ),
        ),
      )),
          // Visible feedback while signing out / disconnecting / deleting,
          // so the screen doesn't just look frozen while that runs.
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x99000000),
                child: Center(
                  child: CircularProgressIndicator(color: _gold),
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }

  /// Logo on the left, "Trigon" on the right (both exactly as drawn in
  /// HomeScreen's top bar), then "Made by NemesisTech", all centered.
  Widget _brandingFooter() {
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/nemesis_logo.png',
              width: 28,
              height: 28,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 8),
            const Text(
              "Trigon",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _gold,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          "Made by NemesisTech",
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white38,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text.isEmpty ? text : text[0].toUpperCase() + text.substring(1).toLowerCase(),
      style: const TextStyle(
        color: Colors.white,
        fontSize: 13,
        fontWeight: FontWeight.w700,
      ),
    );
  }

  Widget _settingsTile({
    IconData? icon,
    Widget? customIcon,
    required String label,
    required String subtitle,
    required VoidCallback onTap,
    bool destructive = false,
  }) {
    final color = destructive ? Colors.redAccent : Colors.white;

    return Pressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            customIcon ?? Icon(icon, color: color, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white24, size: 20),
          ],
        ),
      ),
    );
  }
}
