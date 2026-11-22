import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/external_media_handler.dart';
import '../../../services/jellyfin_services/auth_service.dart';
import '../../../services/parental/parental_controls.dart';
import '../../../services/parental/parental_models.dart';
import '../../../services/parental/pin_vault.dart';
import '../../../services/parental/viewing_time_service.dart';
import '../../../player/player_manager.dart';

const _gold = Color(0xffD4AF37);
const _bg = Color(0xff161616);
const _cardBg = Color(0xff1F1F1F);

/// Every dialog Parental Controls puts in front of the person: PIN entry,
/// PIN creation, "this is blocked" and the "time is up" lock screen.
class ParentalPrompts {
  ParentalPrompts._();

  static NavigatorState? get navigator =>
      ExternalMediaHandler.instance.navigatorKey.currentState;

  static BuildContext? get _rootContext => navigator?.overlay?.context;

  // ------------------------------------------------------------------ PIN

  /// Asks for the PIN. True when it was entered correctly.
  static Future<bool> verifyPin(
    BuildContext? context, {
    String reason = 'Enter your parental PIN',
    bool allowRecovery = true,
  }) async {
    final ctx = _rootContext ?? context;
    if (ctx == null || !ctx.mounted) return false;
    final r = await showDialog<bool>(
      context: ctx,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => _PinDialog(
        mode: _PinMode.verify,
        title: 'Parental PIN',
        subtitle: reason,
        allowRecovery: allowRecovery,
      ),
    );
    return r == true;
  }

  /// Walks through "choose a PIN" + "confirm". Returns the new PIN (already
  /// saved) or null when cancelled.
  static Future<bool> createPin(BuildContext context,
      {String title = 'Create a PIN'}) async {
    final r = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => _PinDialog(
        mode: _PinMode.create,
        title: title,
        subtitle: 'Choose a ${PinVault.pinLength}-digit PIN. You will need it '
            'to change these settings.',
        allowRecovery: false,
      ),
    );
    return r == true;
  }

  // -------------------------------------------------------------- blocked

  /// Tells the person a title is blocked. Offers a parent a PIN to allow it
  /// anyway (for this session). True when it was allowed.
  static Future<bool> showBlocked(Decision d, {String? titleId}) async {
    final ctx = _rootContext;
    if (ctx == null) return false;
    final canOverride = ParentalControls.instance.hasPin.value;
    final r = await showDialog<bool>(
      context: ctx,
      useRootNavigator: true,
      builder: (dctx) => AlertDialog(
        backgroundColor: _cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        icon: const Icon(Icons.lock_outline, color: _gold, size: 30),
        title: const Text('Not available',
            style: TextStyle(color: Colors.white, fontSize: 18)),
        content: Text(
          '${d.message}\n\nBlocked by Parental Controls.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, height: 1.4),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('OK', style: TextStyle(color: Colors.white70)),
          ),
          if (canOverride)
            TextButton(
              onPressed: () async {
                final ok = await verifyPin(dctx,
                    reason: 'Allow this title for now');
                if (ok && dctx.mounted) Navigator.of(dctx).pop(true);
              },
              child: const Text('Parent: allow',
                  style: TextStyle(color: _gold)),
            ),
        ],
      ),
    );
    return r == true;
  }

  /// What a tap on a blocked search result shows: a plain message. The title
  /// is NOT opened and there is no way past it from here. [item] is the
  /// Jellyfin-shaped map of the result.
  static Future<void> showTitleBlocked(BuildContext context, dynamic item) {
    final ctx = _rootContext ?? context;
    final isShow = item is Map && item['Type'] == 'Series';
    final kind = isShow ? 'TV show' : 'Movie';
    final name = item is Map ? '${item['Name'] ?? ''}'.trim() : '';
    return showDialog<void>(
      context: ctx,
      useRootNavigator: true,
      builder: (dctx) => AlertDialog(
        backgroundColor: _cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        icon: const Icon(Icons.lock_outline, color: _gold, size: 30),
        title: Text('$kind blocked',
            style: const TextStyle(color: Colors.white, fontSize: 18)),
        content: Text(
          name.isEmpty
              ? 'This ${kind.toLowerCase()} is blocked by Parental Controls '
                  "and can't be opened."
              : '"$name" is blocked by Parental Controls and '
                  "can't be opened.",
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, height: 1.4),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('OK', style: TextStyle(color: _gold)),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- time lock

  /// Full-screen "time is up / bedtime" screen. True when a parent unlocked
  /// more time (the grant is applied before this returns).
  static Future<bool> showTimeLock(TimeBlock block) async {
    final nav = navigator;
    if (nav == null) return false;
    final r = await nav.push<bool>(PageRouteBuilder<bool>(
      opaque: true,
      fullscreenDialog: true,
      pageBuilder: (_, __, ___) => _TimeLockPage(block: block),
      transitionsBuilder: (_, a, __, child) =>
          FadeTransition(opacity: a, child: child),
    ));
    return r == true;
  }

  /// Re-confirms the signed-in account (password, or a fresh Google prompt).
  static Future<bool> confirmAccountOwner(BuildContext context) async {
    String? password;
    if (AuthService.usesPasswordSignIn) {
      password = await showDialog<String>(
        context: context,
        useRootNavigator: true,
        builder: (d) {
          final c = TextEditingController();
          return AlertDialog(
            backgroundColor: _cardBg,
            title: const Text('Confirm it\'s you',
                style: TextStyle(color: Colors.white)),
            content: TextField(
              controller: c,
              obscureText: true,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Account password',
                hintStyle: TextStyle(color: Colors.white38),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(d).pop(),
                child: const Text('Cancel',
                    style: TextStyle(color: Colors.white54)),
              ),
              TextButton(
                onPressed: () => Navigator.of(d).pop(c.text),
                child: const Text('Continue', style: TextStyle(color: _gold)),
              ),
            ],
          );
        },
      );
      if (password == null || password.isEmpty) return false;
    }
    final result = await AuthService.confirmIdentity(password: password);
    if (result.success) return true;
    if (context.mounted && result.message.isNotEmpty) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(result.message)));
    }
    return false;
  }

  // ----------------------------------------------------------------- misc

  static void toast(String message) {
    final ctx = _rootContext;
    if (ctx == null) return;
    ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xff1A1A1A),
    ));
  }

  /// Stops playback and leaves the player screen.
  static Future<void> closePlayer() async {
    try {
      await PlayerManager.instance.stop();
    } catch (_) {}
    navigator?.popUntil((r) => r.isFirst || r.settings.name == '/home');
  }
}

// ===========================================================================
// PIN dialog
// ===========================================================================

enum _PinMode { verify, create }

class _PinDialog extends StatefulWidget {
  final _PinMode mode;
  final String title;
  final String subtitle;
  final bool allowRecovery;
  const _PinDialog({
    required this.mode,
    required this.title,
    required this.subtitle,
    required this.allowRecovery,
  });

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog>
    with SingleTickerProviderStateMixin {
  String _entry = '';
  String? _first; // create mode: the PIN entered the first time
  String? _message;
  bool _error = false;
  bool _busy = false;
  Duration _locked = Duration.zero;
  Timer? _lockTimer;

  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  @override
  void initState() {
    super.initState();
    if (widget.mode == _PinMode.verify) _refreshLock();
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    _shake.dispose();
    super.dispose();
  }

  Future<void> _refreshLock() async {
    final left = await PinVault.lockRemaining();
    if (!mounted) return;
    setState(() => _locked = left);
    _lockTimer?.cancel();
    if (left > Duration.zero) {
      _lockTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
        final l = await PinVault.lockRemaining();
        if (!mounted) return;
        setState(() => _locked = l);
        if (l <= Duration.zero) t.cancel();
      });
    }
  }

  String get _heading {
    if (widget.mode == _PinMode.create) {
      return _first == null ? widget.title : 'Confirm your PIN';
    }
    return widget.title;
  }

  String get _sub {
    if (_message != null) return _message!;
    if (widget.mode == _PinMode.create && _first != null) {
      return 'Enter the same PIN again.';
    }
    if (_locked > Duration.zero) {
      return 'Too many tries. Try again in ${PinVault.describeLock(_locked)}.';
    }
    return widget.subtitle;
  }

  void _digit(String d) {
    if (_busy || _locked > Duration.zero) return;
    if (_entry.length >= PinVault.pinLength) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entry += d;
      _error = false;
      _message = null;
    });
    if (_entry.length == PinVault.pinLength) unawaited(_submit());
  }

  void _back() {
    if (_busy || _entry.isEmpty) return;
    setState(() => _entry = _entry.substring(0, _entry.length - 1));
  }

  Future<void> _fail(String message) async {
    HapticFeedback.heavyImpact();
    setState(() {
      _error = true;
      _message = message;
      _busy = false;
    });
    await _shake.forward(from: 0);
    if (!mounted) return;
    setState(() => _entry = '');
  }

  Future<void> _submit() async {
    final pin = _entry;
    setState(() => _busy = true);

    if (widget.mode == _PinMode.verify) {
      final r = await PinVault.verify(pin);
      if (!mounted) return;
      if (r.ok) {
        Navigator.of(context).pop(true);
        return;
      }
      if (r.locked != null) {
        await _fail('Too many tries.');
        await _refreshLock();
        return;
      }
      final left = r.attemptsLeft ?? 0;
      await _fail(left <= 1
          ? 'Wrong PIN. $left try left before a short lock.'
          : 'Wrong PIN. $left tries left before a short lock.');
      return;
    }

    // create
    if (_first == null) {
      if (PinVault.isWeak(pin)) {
        await _fail('That PIN is too easy to guess. Try another.');
        return;
      }
      setState(() {
        _first = pin;
        _entry = '';
        _busy = false;
      });
      return;
    }
    if (pin != _first) {
      setState(() => _first = null);
      await _fail("The PINs didn't match. Start again.");
      return;
    }
    await ParentalControls.instance.setPin(pin);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _forgot() async {
    final ok = await _recover(context);
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return Dialog(
      backgroundColor: _cardBg,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: w < 360 ? w : 340),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, color: _gold, size: 28),
              const SizedBox(height: 10),
              Text(_heading,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(
                _sub,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _error || _locked > Duration.zero
                      ? Colors.redAccent
                      : Colors.white54,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 20),
              AnimatedBuilder(
                animation: _shake,
                builder: (_, child) {
                  final dx = (1 - _shake.value) *
                      12 *
                      (((_shake.value * 6).floor()).isEven ? 1 : -1);
                  return Transform.translate(
                      offset: Offset(_shake.isAnimating ? dx : 0, 0),
                      child: child);
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < PinVault.pinLength; i++)
                      Container(
                        width: 14,
                        height: 14,
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i < _entry.length
                              ? (_error ? Colors.redAccent : _gold)
                              : Colors.transparent,
                          border: Border.all(
                            color: _error ? Colors.redAccent : Colors.white38,
                            width: 1.5,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _keypad(),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel',
                        style: TextStyle(color: Colors.white54)),
                  ),
                  if (widget.mode == _PinMode.verify && widget.allowRecovery)
                    TextButton(
                      onPressed: _forgot,
                      child: const Text('Forgot PIN?',
                          style: TextStyle(color: _gold)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _keypad() {
    Widget key(String label, {VoidCallback? onTap, IconData? icon}) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: AspectRatio(
            aspectRatio: 1.45,
            child: Material(
              color: onTap == null ? Colors.transparent : _bg,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: onTap,
                child: Center(
                  child: icon != null
                      ? Icon(icon, color: Colors.white70, size: 22)
                      : Text(label,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w500)),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget row(List<String> digits) => Row(children: [
          for (final d in digits) key(d, onTap: () => _digit(d)),
        ]);

    return Column(children: [
      row(['1', '2', '3']),
      row(['4', '5', '6']),
      row(['7', '8', '9']),
      Row(children: [
        key('', onTap: null),
        key('0', onTap: () => _digit('0')),
        key('', onTap: _back, icon: Icons.backspace_outlined),
      ]),
    ]);
  }
}

// ===========================================================================
// "Forgot PIN" - the account owner proves who they are, then picks a new PIN
// ===========================================================================

/// Account password / Google re-confirmation, then a new PIN. Guests have no
/// account to confirm, so they cannot recover a forgotten PIN.
Future<bool> _recover(BuildContext context) async {
  if (AuthService.isGuest || !AuthService.isSignedIn) {
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (d) => AlertDialog(
        backgroundColor: _cardBg,
        title: const Text('Forgot your PIN?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          "You're using the app without an account, so there's nothing to "
          'confirm your identity with. The PIN can only be reset by clearing '
          "the app's storage in Android Settings, which also removes your "
          'saved data on this device.',
          style: TextStyle(color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(),
            child: const Text('OK', style: TextStyle(color: _gold)),
          ),
        ],
      ),
    );
    return false;
  }

  final confirmed = await ParentalPrompts.confirmAccountOwner(context);
  if (!confirmed || !context.mounted) return false;
  return ParentalPrompts.createPin(context, title: 'Choose a new PIN');
}

// ===========================================================================
// Time lock screen
// ===========================================================================

class _TimeLockPage extends StatelessWidget {
  final TimeBlock block;
  const _TimeLockPage({required this.block});

  Future<void> _askParent(BuildContext context) async {
    final ok = await ParentalPrompts.verifyPin(context,
        reason: block.reason == BlockReason.bedtime
            ? 'Allow watching tonight'
            : 'Give more watch time');
    if (!ok || !context.mounted) return;

    final isBedtime = block.reason == BlockReason.bedtime;
    final options = isBedtime
        ? const <(String, int)>[
            ('30 more minutes', 30),
            ('1 more hour', 60),
            ('2 more hours', 120),
          ]
        : const <(String, int)>[
            ('15 more minutes', 15),
            ('30 more minutes', 30),
            ('1 more hour', 60),
          ];

    final minutes = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      backgroundColor: const Color(0xff181818),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (s) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            const Text('Allow watching for',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            for (final o in options)
              ListTile(
                leading: const Icon(Icons.timer_outlined, color: _gold),
                title:
                    Text(o.$1, style: const TextStyle(color: Colors.white)),
                onTap: () => Navigator.of(s).pop(o.$2),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (minutes == null || !context.mounted) return;

    if (isBedtime) {
      await ViewingTimeService.instance.liftBedtime(Duration(minutes: minutes));
    } else {
      await ViewingTimeService.instance.grantMinutes(minutes);
    }
    if (context.mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isBedtime = block.reason == BlockReason.bedtime;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _gold.withValues(alpha: 0.12),
                      ),
                      child: Icon(
                        isBedtime
                            ? Icons.bedtime_outlined
                            : Icons.hourglass_bottom_rounded,
                        color: _gold,
                        size: 40,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(block.title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 10),
                    Text(block.message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 15, height: 1.4)),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: _gold,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('OK',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    ),
                    if (ParentalControls.instance.hasPin.value)
                      TextButton(
                        onPressed: () => _askParent(context),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text('Ask a parent for more time',
                              style: TextStyle(color: _gold)),
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
}
