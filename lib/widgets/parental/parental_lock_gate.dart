import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../screens/main_nav/navigation_controller.dart';
import '../../screens/profile/parental/parental_prompts.dart';
import '../../screens/profile/parental/parental_widgets.dart'
    show pcBg, pcGold;
import '../../services/parental/parental_controls.dart';
import '../../services/parental/parental_models.dart';

/// Keeps a page behind the parental PIN when the parent turned that lock on
/// (Parental Controls > Protection).
///
/// While the page is locked its [child] is NOT built at all, so nothing of
/// it is visible or reachable; a lock screen is shown instead and the PIN
/// is asked for straight away. Cancelling the PIN leaves the lock screen,
/// which has an "Enter PIN" button to try again.
///
/// Two ways to host it:
///  * as a bottom-nav / rail tab (pass [tabIndex]): the PIN is asked every
///    time the tab is entered, and the page locks again as soon as another
///    tab is selected;
///  * as a pushed route ([tabIndex] null): the PIN is asked when the route
///    opens; popping the route locks it again.
///
/// The lock only applies while Parental Controls are on, not paused, and a
/// PIN exists - the same rule as the other PIN locks
/// ([ParentalControls.isAreaLocked]).
class ParentalLockGate extends StatefulWidget {
  final LockedArea area;

  /// The [NavTabs] index this gate lives at when it is a tab of the main
  /// navigation; null when it is the content of a pushed route.
  final int? tabIndex;

  final Widget child;

  const ParentalLockGate({
    super.key,
    required this.area,
    required this.child,
    this.tabIndex,
  });

  @override
  State<ParentalLockGate> createState() => _ParentalLockGateState();
}

class _ParentalLockGateState extends State<ParentalLockGate> {
  final ParentalControls _pc = ParentalControls.instance;
  late final Listenable _listenable;

  bool _unlocked = false;
  bool _prompting = false;
  bool _wasVisible = false;
  bool _wasRequired = false;

  bool get _isVisible =>
      widget.tabIndex == null ||
      NavigationController.instance.tabIndex == widget.tabIndex;

  bool get _required => _pc.isAreaLocked(widget.area);

  String get _reason => widget.area == LockedArea.downloads
      ? 'Open Downloads'
      : 'Open Favorites';

  @override
  void initState() {
    super.initState();
    _listenable = Listenable.merge([
      _pc.settings,
      _pc.pausedUntil,
      _pc.hasPin,
      NavigationController.instance,
    ]);
    _listenable.addListener(_sync);
    if (_evaluate()) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _prompt());
    }
  }

  @override
  void dispose() {
    _listenable.removeListener(_sync);
    super.dispose();
  }

  /// Updates the lock state for the current situation. True when the PIN
  /// should be asked for now: the page was just entered, or the lock was
  /// just switched on while it is showing.
  bool _evaluate() {
    final visible = _isVisible;
    final required = _required;

    // Leaving the page (or the lock being switched off) locks it again, so
    // the PIN is needed the next time it is entered.
    if (!visible || !required) _unlocked = false;

    final shouldPrompt = visible &&
        required &&
        !_unlocked &&
        (!_wasVisible || !_wasRequired);
    _wasVisible = visible;
    _wasRequired = required;
    return shouldPrompt;
  }

  void _sync() {
    if (!mounted) return;
    // A notifier can fire while the tree is building; wait for the frame.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
      return;
    }
    final prompt = _evaluate();
    setState(() {});
    if (prompt) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _prompt());
    }
  }

  Future<void> _prompt() async {
    if (!mounted || _prompting || _unlocked) return;
    if (!_isVisible || !_required) return;

    _prompting = true;
    final ok = await ParentalPrompts.verifyPin(context, reason: _reason);
    _prompting = false;
    if (!mounted) return;

    // Only unlock if this page is still the one being shown and still locked.
    if (ok && _isVisible && _required) {
      setState(() => _unlocked = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked || !_required) return widget.child;
    return _LockedView(area: widget.area, onEnterPin: _prompt);
  }
}

class _LockedView extends StatelessWidget {
  final LockedArea area;
  final VoidCallback onEnterPin;
  const _LockedView({required this.area, required this.onEnterPin});

  @override
  Widget build(BuildContext context) {
    final isDownloads = area == LockedArea.downloads;
    final canPop = Navigator.of(context).canPop();

    return Scaffold(
      backgroundColor: pcBg,
      appBar: canPop
          ? AppBar(
              backgroundColor: pcBg,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              leading: const BackButton(color: Colors.white),
            )
          : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
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
                      color: pcGold.withValues(alpha: 0.12),
                    ),
                    child: const Icon(Icons.lock_outline,
                        color: pcGold, size: 40),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    isDownloads ? 'Downloads locked' : 'Favorites locked',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    isDownloads
                        ? 'Enter the parental PIN to open your downloads.'
                        : 'Enter the parental PIN to open your favorites.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 15,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: pcGold,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: onEnterPin,
                      icon: const Icon(Icons.pin_outlined, size: 20),
                      label: const Text(
                        'Enter PIN',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      if (canPop) {
                        Navigator.of(context).pop();
                      } else {
                        NavigationController.instance.goToTab(NavTabs.home);
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        canPop ? 'Go back' : 'Back to Home',
                        style: const TextStyle(color: pcGold),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
