import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/jellyfin_services/auth_service.dart';
import '../../services/parental/parental_controls.dart';
import '../../services/parental/parental_models.dart';
import '../../services/parental/viewing_time_service.dart';
import '../../widgets/common/keyboard_safe_dialog.dart';
import '../../widgets/common/pressable.dart';
import 'parental/blocked_titles_screen.dart';
import 'parental/parental_prompts.dart';
import 'parental/parental_widgets.dart';
import 'parental/screen_time_screen.dart';

/// Parental Controls: PIN-protected, device-wide content and screen-time
/// controls. See ParentalControls for how the rules are enforced.
class ParentalControlsScreen extends StatefulWidget {
  const ParentalControlsScreen({super.key});

  @override
  State<ParentalControlsScreen> createState() => _ParentalControlsScreenState();
}

class _ParentalControlsScreenState extends State<ParentalControlsScreen> {
  final ParentalControls _pc = ParentalControls.instance;

  bool _unlocked = false;
  late final int _startRevision;

  @override
  void initState() {
    super.initState();
    _startRevision = _pc.revision.value;
    WidgetsBinding.instance.addPostFrameCallback((_) => _gate());
  }

  /// With a PIN set, nothing is shown until it is entered.
  Future<void> _gate() async {
    if (!_pc.hasPin.value) {
      if (mounted) setState(() => _unlocked = true);
      return;
    }
    final ok = await ParentalPrompts.verifyPin(
      context,
      reason: 'Enter your PIN to open Parental Controls',
    );
    if (!mounted) return;
    if (ok) {
      setState(() => _unlocked = true);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  ParentalSettings get _s => _pc.settings.value;

  Future<void> _update(ParentalSettings Function(ParentalSettings) f) async {
    await _pc.save(f(_s));
    if (mounted) setState(() {});
  }

  /// Changes that affect what is listed rebuild the app once on the way
  /// out, so no screen keeps showing lists from before.
  void _onPopped(bool didPop) {
    if (!didPop) return;
    if (_pc.revision.value != _startRevision) {
      unawaited(_pc.refreshApp());
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, _) => _onPopped(didPop),
      child: ValueListenableBuilder<ParentalSettings>(
        valueListenable: _pc.settings,
        builder: (context, s, _) => ValueListenableBuilder<DateTime?>(
          valueListenable: _pc.pausedUntil,
          builder: (context, paused, _) {
            if (!_unlocked) {
              return const Scaffold(
                backgroundColor: pcBg,
                body: Center(child: CircularProgressIndicator(color: pcGold)),
              );
            }
            if (_pc.needsPinReset) return _recovery();
            if (!s.enabled && !_pc.hasPin.value) return _intro();
            return _main(s);
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- intro

  Widget _intro() {
    Widget point(IconData icon, String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: pcGold, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(body,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 13, height: 1.35)),
                  ],
                ),
              ),
            ],
          ),
        );

    return PcPage(
      title: 'Parental Controls',
      children: [
        const SizedBox(height: 8),
        const Text(
          'Make this a safe place to watch',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'Set what can be watched, who can watch it and for how long. Protected '
          'by your PIN.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54, fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 28),
        point(Icons.child_care_outlined, 'Age limits',
            'Pick between Little Kids, Kids, Teens or Mature. Anything above the limit set is '
                'hidden everywhere and cannot be played.'),
        point(Icons.block_outlined, 'Block specific things',
            'Hide individual titles, whole genres, or titles that mention '
                'words you choose.'),
        point(Icons.timer_outlined, 'Screen time',
            'A daily watch limit for each day of the week, plus a bedtime.'),
        point(Icons.lock_outline, 'PIN protected',
            'Settings, signing out and overrides all need your PIN, so a '
                'child cannot get around it by signing out.'),
        const SizedBox(height: 12),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: pcGold,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
          ),
          onPressed: _setUp,
          child: const Text('Create a PIN and get started',
              style: TextStyle(fontWeight: FontWeight.w700)),
        ),
        if (AuthService.isGuest) ...[
          const SizedBox(height: 14),
          const Text(
            "You're using the app without an account, so a forgotten PIN "
            "can't be recovered. Choose one you will remember.",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.4),
          ),
        ],
      ],
    );
  }

  Future<void> _setUp() async {
    final ok = await ParentalPrompts.createPin(context);
    if (!ok || !mounted) return;
    await _update((s) => s.copyWith(enabled: true));
  }

  // ------------------------------------------------------------- recovery

  Widget _recovery() {
    return PcPage(
      title: 'Parental Controls',
      children: [
        const SizedBox(height: 8),
        PcBanner(
          icon: Icons.lock_reset,
          color: Colors.orangeAccent,
          child: const Text(
            "The PIN for this device couldn't be found (this can happen "
            'after reinstalling the app). Restrictions are still being '
            'enforced. Confirm your account to choose a new PIN.',
            style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: pcGold,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
          ),
          onPressed: () async {
            if (AuthService.isGuest || !AuthService.isSignedIn) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text(
                    "Without an account the PIN can't be reset. Clear the "
                    "app's storage in Android Settings."),
              ));
              return;
            }
            final ok = await ParentalPrompts.confirmAccountOwner(context);
            if (!ok || !mounted) return;
            await ParentalPrompts.createPin(context,
                title: 'Choose a new PIN');
            if (mounted) setState(() {});
          },
          child: const Text('Confirm account and reset PIN',
              style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }

  // ----------------------------------------------------------------- main

  Widget _main(ParentalSettings s) {
    final paused = _pc.isPaused;
    final until = _pc.pausedUntil.value;

    return PcPage(
      title: 'Parental Controls',
      children: [
        // Master switch + pause -------------------------------------------
        PcToggle(
          label: 'Parental Controls',
          subtitle: s.enabled
              ? 'On for everyone using this device'
              : 'Off, your settings are kept',
          value: s.enabled,
          onChanged: (v) => _update((c) => c.copyWith(enabled: v)),
        ),
        if (s.enabled) ...[
          const SizedBox(height: 10),
          if (paused && until != null)
            PcBanner(
              icon: Icons.pause_circle_outline,
              color: Colors.orangeAccent,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Paused until '
                      '${ScreenTime.formatClock(until.hour * 60 + until.minute)}. '
                      'Nothing is restricted right now.',
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 13, height: 1.35),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await _pc.setPaused(null);
                      if (mounted) setState(() {});
                    },
                    child: const Text('Resume',
                        style: TextStyle(color: pcGold)),
                  ),
                ],
              ),
            )
          else
            PcTile(
              icon: Icons.pause_circle_outline,
              label: 'Pause restrictions',
              subtitle: 'Let a grown-up watch freely for a while',
              onTap: _pauseSheet,
            ),
        ],

        // Maturity ---------------------------------------------------------
        const PcSection(
          "Who's watching",
          hint: 'Titles rated above limit set are hidden and cannot be played.',
        ),
        for (final t in kMaturityTiers) ...[
          _tierCard(t, s),
          const SizedBox(height: 8),
        ],
        PcToggle(
          icon: Icons.help_outline,
          label: 'Hide unrated titles',
          subtitle: s.hasMaturityLimit
              ? 'Hide anything without an age rating we can read'
              : 'Applies once an age limit is chosen',
          value: s.blockUnrated,
          onChanged: s.hasMaturityLimit
              ? (v) => _update((c) => c.copyWith(blockUnrated: v))
              : null,
        ),

        // Custom blocks ----------------------------------------------------
        const PcSection('Block more'),
        PcTile(
          icon: Icons.movie_outlined,
          label: 'Blocked titles',
          subtitle: s.blockedTitles.isEmpty
              ? 'Search and block a specific movie or show'
              : '${s.blockedTitles.length} blocked',
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BlockedTitlesScreen()),
            );
            if (mounted) setState(() {});
          },
        ),
        const SizedBox(height: 10),
        PcTile(
          icon: Icons.category_outlined,
          label: 'Blocked genres',
          subtitle: s.blockedGenres.isEmpty
              ? 'None'
              : (s.blockedGenres
                      .map((k) => genreByKey(k)?.label ?? k)
                      .toList()
                    ..sort())
                  .join(', '),
          onTap: _genreSheet,
        ),
        const SizedBox(height: 10),
        PcTile(
          icon: Icons.spellcheck_outlined,
          label: 'Blocked words',
          subtitle: s.blockedWords.isEmpty
              ? 'Block titles whose name or story mentions a word'
              : s.blockedWords.join(', '),
          onTap: _wordsDialog,
        ),

        // Screen time ------------------------------------------------------
        const PcSection('Screen time'),
        ValueListenableBuilder<int>(
          valueListenable: ViewingTimeService.instance.usedSeconds,
          builder: (context, used, _) => PcTile(
            icon: Icons.timer_outlined,
            label: 'Daily limit and bedtime',
            subtitle: _timeSummary(s, used),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ScreenTimeScreen()),
              );
              if (mounted) setState(() {});
            },
          ),
        ),

        // Protection -------------------------------------------------------
        const PcSection('Protection'),
        PcToggle(
          icon: Icons.logout,
          label: 'PIN to sign out or delete account',
          subtitle: 'Stops signing out into a different session',
          value: s.lockAccountActions,
          onChanged: (v) => _update((c) => c.copyWith(lockAccountActions: v)),
        ),
        const SizedBox(height: 10),
        PcToggle(
          icon: Icons.extension_outlined,
          label: 'PIN to manage add-ons',
          subtitle: 'Add-ons provide the streams',
          value: s.lockAddons,
          onChanged: (v) => _update((c) => c.copyWith(lockAddons: v)),
        ),
        const SizedBox(height: 10),
        PcToggle(
          icon: Icons.download_outlined,
          label: 'PIN to open Downloads',
          subtitle: 'The Downloads page asks for the PIN every time',
          value: s.lockDownloads,
          onChanged: (v) => _update((c) => c.copyWith(lockDownloads: v)),
        ),
        const SizedBox(height: 10),
        PcToggle(
          icon: Icons.favorite_border,
          label: 'PIN to open Favorites',
          subtitle: 'The Favorites page asks for the PIN every time',
          value: s.lockFavorites,
          onChanged: (v) => _update((c) => c.copyWith(lockFavorites: v)),
        ),
        const SizedBox(height: 10),
        PcTile(
          icon: Icons.password_outlined,
          label: 'Change PIN',
          subtitle: 'Choose a new 4-digit PIN',
          onTap: () async {
            await ParentalPrompts.createPin(context, title: 'Choose a new PIN');
          },
        ),
        const SizedBox(height: 10),
        PcTile(
          icon: Icons.delete_outline,
          label: 'Remove Parental Controls',
          subtitle: 'Turn everything off and forget the PIN',
          destructive: true,
          onTap: _removeAll,
        ),
        const SizedBox(height: 20),
        const Text(
          'Important note: These controls apply to this device, including Guest mode and '
          'other accounts. They filter and block what this app shows and '
          'plays. They cannot stop someone clearing the app\'s data or '
          'uninstalling it; for that, use a device-level tool such as '
          'Google Family Link.',
          style: TextStyle(color: Colors.white30, fontSize: 12, height: 1.4),
        ),
      ],
    );
  }

  String _timeSummary(ParentalSettings s, int usedSeconds) {
    final parts = <String>[];
    if (s.hasDailyLimit) {
      final today = ScreenTime.limitFor(s, DateTime.now());
      if (today == null) {
        parts.add('No limit today');
      } else {
        final left = today * 60 - usedSeconds;
        parts.add(left <= 0
            ? "Today's time is used up"
            : '${ScreenTime.formatDuration(Duration(seconds: left))} left today');
      }
    }
    if (s.bedtimeEnabled) {
      parts.add('Bedtime ${ScreenTime.formatClock(s.bedtimeStartMin)} - '
          '${ScreenTime.formatClock(s.bedtimeEndMin)}');
    }
    return parts.isEmpty ? 'No limits set' : parts.join('  |  ');
  }

  // ---------------------------------------------------------------- tiers

  Widget _tierCard(MaturityTier t, ParentalSettings s) {
    final selected = s.maxLevel == t.level;
    return Pressable(
      onTap: () => _update((c) => c.copyWith(maxLevel: t.level)),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: pcCardBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? pcGold : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? pcGold : Colors.white38,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.name,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    t.level == kNoLimitLevel
                        ? t.blurb
                        : 'Movies: ${t.movies}  |  Shows: ${t.shows}',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 12, height: 1.35),
                  ),
                  if (t.level != kNoLimitLevel) ...[
                    const SizedBox(height: 3),
                    Text(t.blurb,
                        style: const TextStyle(
                            color: Colors.white30, fontSize: 12, height: 1.35)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- pause

  Future<void> _pauseSheet() async {
    const options = <(String, Duration)>[
      ('30 minutes', Duration(minutes: 30)),
      ('1 hour', Duration(hours: 1)),
      ('3 hours', Duration(hours: 3)),
      ('Until tomorrow', Duration(hours: 24)),
    ];
    final picked = await showModalBottomSheet<Duration>(
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
            const Text('Pause restrictions for',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            for (final o in options)
              ListTile(
                leading: const Icon(Icons.pause_circle_outline, color: pcGold),
                title: Text(o.$1, style: const TextStyle(color: Colors.white)),
                onTap: () => Navigator.of(s).pop(o.$2),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await _pc.setPaused(picked);
    if (mounted) setState(() {});
  }

  // --------------------------------------------------------------- genres

  Future<void> _genreSheet() async {
    final chosen = {..._s.blockedGenres};
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xff181818),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Blocked genres',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                const Text(
                    'Titles in a selected genre are hidden and cannot be played.',
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final g in kBlockableGenres)
                      FilterChip(
                        label: Text(g.label),
                        selected: chosen.contains(g.key),
                        showCheckmark: false,
                        labelStyle: TextStyle(
                          color: chosen.contains(g.key)
                              ? Colors.black
                              : Colors.white70,
                          fontSize: 13,
                        ),
                        backgroundColor: pcCardBg,
                        selectedColor: pcGold,
                        side: BorderSide(
                          color: chosen.contains(g.key)
                              ? pcGold
                              : Colors.white12,
                        ),
                        onSelected: (v) => setSheet(() {
                          v ? chosen.add(g.key) : chosen.remove(g.key);
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: pcGold,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () => Navigator.of(sheetCtx).pop(),
                    child: const Text('Done',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await _update((c) => c.copyWith(blockedGenres: chosen));
  }

  // ---------------------------------------------------------------- words

  Future<void> _wordsDialog() async {
    final words = [..._s.blockedWords];
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dctx) => KeyboardSafeDialog(
        child: StatefulBuilder(
          builder: (ctx, setD) {
            void add() {
              final w = controller.text.trim();
              if (w.isEmpty || w.length > 40) return;
              if (!words.any((e) => e.toLowerCase() == w.toLowerCase())) {
                setD(() => words.add(w));
              }
              controller.clear();
            }

            return AlertDialog(
              backgroundColor: pcCardBg,
              title: const Text('Blocked words',
                  style: TextStyle(color: Colors.white)),
              content: SizedBox(
                width: 340,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Titles whose name or story contains one of these "
                      "words are blocked.",
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller,
                      style: const TextStyle(color: Colors.white),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => add(),
                      decoration: InputDecoration(
                        hintText: 'Add a word or phrase',
                        hintStyle: const TextStyle(color: Colors.white38),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.add, color: pcGold),
                          onPressed: add,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final w in words)
                          InputChip(
                            label: Text(w),
                            labelStyle: const TextStyle(
                                color: Colors.white70, fontSize: 13),
                            backgroundColor: pcBg,
                            side: const BorderSide(color: Colors.white12),
                            deleteIconColor: Colors.white38,
                            onDeleted: () => setD(() => words.remove(w)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dctx).pop(),
                  child: const Text('Done', style: TextStyle(color: pcGold)),
                ),
              ],
            );
          },
        ),
      ),
    );
    // Whatever was typed but not yet added still counts.
    final pending = controller.text.trim();
    if (pending.isNotEmpty &&
        pending.length <= 40 &&
        !words.any((e) => e.toLowerCase() == pending.toLowerCase())) {
      words.add(pending);
    }
    controller.dispose();
    await _update((c) => c.copyWith(blockedWords: words));
  }

  // --------------------------------------------------------------- remove

  Future<void> _removeAll() async {
    final ok = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (d) => AlertDialog(
        backgroundColor: pcCardBg,
        title: const Text('Remove Parental Controls?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'This turns off every restriction and screen-time rule and forgets '
          'your PIN.',
          style: TextStyle(color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: const Text('Remove',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _pc.removeAll();
    if (mounted) Navigator.of(context).maybePop();
  }
}
