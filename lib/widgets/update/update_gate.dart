import 'package:flutter/material.dart';

import '../../services/update/update_config.dart';
import '../../services/update/update_models.dart';
import '../../services/update/update_service.dart';
import '../../utils/app_fonts.dart';
import '../common/pressable.dart';

const Color _gold = Color(0xFFD4AF37);

/// Puts the update popup above the whole app (every screen, dialog and the
/// video player), so a mandatory update can not be bypassed by opening
/// something else. Used once, in MaterialApp.builder (see main.dart).
///
/// All state and logic live in [UpdateService]; this only draws it:
///  * optional update  - "Download & Install" / "Don't remind" / "Later"
///  * mandatory update - "Exit" / "Update", no way around it
///  * then, inside the same card: permission step, download progress,
///    verification, installer hand-off, errors with "Try again".
class UpdateGate extends StatelessWidget {
  const UpdateGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        ListenableBuilder(
          listenable: UpdateService.instance,
          builder: (context, _) {
            final svc = UpdateService.instance;
            final show = svc.promptVisible && svc.info != null;
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (c, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.96, end: 1.0).animate(animation),
                  child: c,
                ),
              ),
              child: show
                  ? _UpdateOverlay(key: const ValueKey('update-overlay'), svc: svc)
                  : const SizedBox.shrink(key: ValueKey('update-none')),
            );
          },
        ),
      ],
    );
  }
}

class _UpdateOverlay extends StatelessWidget {
  const _UpdateOverlay({super.key, required this.svc});

  final UpdateService svc;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final maxCardHeight =
        (mq.size.height - mq.padding.vertical - 32).clamp(240.0, 900.0);

    return Material(
      type: MaterialType.transparency,
      child: SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Scrim. Swallows every touch so nothing underneath can be used;
            // for an optional update a tap outside means "Later".
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: (!svc.mandatory && !svc.busy) ? svc.dismissLater : null,
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.78)),
            ),
            SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: 440,
                    maxHeight: maxCardHeight.toDouble(),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
                      decoration: BoxDecoration(
                        color: const Color(0xFF161616),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.10),
                        ),
                      ),
                      child: SingleChildScrollView(
                        child: _CardBody(svc: svc),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CardBody extends StatelessWidget {
  const _CardBody({required this.svc});

  final UpdateService svc;

  @override
  Widget build(BuildContext context) {
    final info = svc.info!;
    final mandatory = info.mandatory;

    final Widget body;
    switch (svc.phase) {
      case UpdatePhase.needsPermission:
        body = _PermissionBody(svc: svc);
        break;
      case UpdatePhase.downloading:
      case UpdatePhase.verifying:
        body = _ProgressBody(svc: svc);
        break;
      case UpdatePhase.installing:
        body = const _InstallingBody();
        break;
      case UpdatePhase.readyToInstall:
        body = _ReadyBody(svc: svc);
        break;
      case UpdatePhase.error:
        body = _ErrorBody(svc: svc);
        break;
      case UpdatePhase.idle:
      case UpdatePhase.available:
        body = _AvailableBody(svc: svc, info: info);
        break;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(mandatory: mandatory),
        const SizedBox(height: 20),
        _VersionRow(info: info),
        const SizedBox(height: 18),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: KeyedSubtree(key: ValueKey(svc.phase), child: body),
          ),
        ),
      ],
    );
  }
}

// ───────────────────────────── header + versions ─────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.mandatory});

  final bool mandatory;

  @override
  Widget build(BuildContext context) {
    final accent = mandatory ? const Color(0xFFFF8A65) : _gold;
    return Row(
      children: [
        Icon(Icons.cloud_download_outlined, color: accent, size: 46),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                mandatory ? 'Update required' : 'Update available',
                style: AppFonts.dosis(fontSize: 25, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                mandatory
                    ? 'This version is no longer supported'
                    : 'A new version is ready',
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VersionRow extends StatelessWidget {
  const _VersionRow({required this.info});

  final UpdateInfo info;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _VersionChip(label: 'Current', value: 'v${info.current}'),
        const Padding(
          padding: EdgeInsets.only(bottom: 7, left: 10, right: 10),
          child: Icon(Icons.chevron_right_rounded, color: _gold, size: 24),
        ),
        _VersionChip(label: 'New', value: 'v${info.latest.version}', highlight: true),
      ],
    );
  }
}

class _VersionChip extends StatelessWidget {
  const _VersionChip({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: highlight
                  ? _gold.withValues(alpha: 0.45)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Text(
            value,
            style: TextStyle(
              color: highlight ? _gold : Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

// ───────────────────────────── phase bodies ─────────────────────────────

class _AvailableBody extends StatelessWidget {
  const _AvailableBody({required this.svc, required this.info});

  final UpdateService svc;
  final UpdateInfo info;

  @override
  Widget build(BuildContext context) {
    final notes = info.latest.notes.isEmpty
        ? 'Bug fixes and improvements.'
        : info.latest.notes;
    final size = info.latest.apkSize;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (info.mandatory) ...[
          _MandatoryNotice(info: info),
          const SizedBox(height: 14),
        ],
        const _SectionLabel("What's new"),
        const SizedBox(height: 8),
        Container(
          constraints: const BoxConstraints(maxHeight: 170),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: SingleChildScrollView(
            child: Text(
              notes,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13.5,
                height: 1.45,
              ),
            ),
          ),
        ),
        if (size > 0) ...[
          const SizedBox(height: 10),
          Text(
            'Download size  ·  ${_mb(size)}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
        const SizedBox(height: 18),
        if (info.mandatory)
          _PrimaryButton(
            label: 'Update App',
            icon: Icons.cloud_download_outlined,
            onTap: svc.startUpdate,
          )
        else ...[
          _PrimaryButton(
            label: 'Update now',
            icon: Icons.cloud_download_outlined,
            onTap: svc.startUpdate,
          ),
          const SizedBox(height: 10),
          _SecondaryButton(label: 'Not now', onTap: svc.dismissLater),
        ],
      ],
    );
  }
}

/// The explanation shown when an update can not be skipped.
class _MandatoryNotice extends StatelessWidget {
  const _MandatoryNotice({required this.info});

  final UpdateInfo info;

  @override
  Widget build(BuildContext context) {
    final byCount =
        info.majorUpdatesBehind >= UpdateConfig.forceAfterMajorUpdates;
    final String text;
    if (byCount) {
      final n = info.majorUpdatesBehind;
      text = 'Your version of Trigon is $n releases behind. Versions '
          '${UpdateConfig.forceAfterMajorUpdates} or more releases old stop '
          'working, so streaming, downloads and security keep working '
          'properly. Please update to keep using Trigon.';
    } else {
      text = 'This update contains an important fix, so it has to be '
          'installed before you can keep using Trigon.';
    }
    return _NoticeBox(
      icon: Icons.info_outline_rounded,
      color: const Color(0xFFFF8A65),
      title: 'You need to update to continue',
      text: text,
    );
  }
}

class _PermissionBody extends StatelessWidget {
  const _PermissionBody({required this.svc});

  final UpdateService svc;

  @override
  Widget build(BuildContext context) {
    final mandatory = svc.mandatory;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _NoticeBox(
          icon: Icons.shield_outlined,
          color: _gold,
          title: 'Allow Trigon to install the update',
          text: 'Android needs your OK before an app can install updates. '
              'Tap "Open settings", switch on "Allow from this source" for '
              'Trigon, then come back - the update continues by itself.',
        ),
        const SizedBox(height: 18),
        _PrimaryButton(
          label: 'Open settings',
          icon: Icons.settings_outlined,
          onTap: svc.openInstallSettings,
        ),
        if (!mandatory) ...[
          const SizedBox(height: 10),
          _SecondaryButton(label: 'Not now', onTap: svc.dismissLater),
        ],
      ],
    );
  }
}

class _ProgressBody extends StatelessWidget {
  const _ProgressBody({required this.svc});

  final UpdateService svc;

  @override
  Widget build(BuildContext context) {
    final verifying = svc.phase == UpdatePhase.verifying;
    final progress = verifying ? null : svc.progress;
    final received = svc.receivedBytes;
    final total = svc.totalBytes;
    final percent = progress == null ? null : (progress * 100).floor();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2.2, color: _gold),
            ),
            const SizedBox(width: 12),
            Text(
              verifying ? 'Verifying download...' : 'Downloading...',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _GoldProgressBar(value: progress),
        const SizedBox(height: 10),
        if (!verifying)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                total > 0
                    ? '${_mb(received)} / ${_mb(total)}'
                    : _mb(received),
                style: const TextStyle(color: Colors.white, fontSize: 12.5),
              ),
              if (percent != null)
                Text(
                  '$percent%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        if (!verifying) ...[
          const SizedBox(height: 18),
          _SecondaryButton(label: 'Cancel', onTap: svc.cancelDownload),
        ],
      ],
    );
  }
}

/// Pill-shaped progress bar: a gold outline with a gold fill inside it.
/// [value] is 0..1, or null for an indeterminate (verifying) bar.
class _GoldProgressBar extends StatelessWidget {
  const _GoldProgressBar({required this.value});

  final double? value;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 16,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _gold, width: 1.5),
      ),
      child: value == null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: const LinearProgressIndicator(
                color: _gold,
                backgroundColor: Colors.transparent,
              ),
            )
          : Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: value!.clamp(0.0, 1.0).toDouble(),
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _gold,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ),
    );
  }
}

class _InstallingBody extends StatelessWidget {
  const _InstallingBody();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: _gold),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Opening the installer... Follow the Android prompt and tap '
              'Install to finish updating. Trigon restarts by itself '
              'afterwards.',
              style: TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadyBody extends StatelessWidget {
  const _ReadyBody({required this.svc});

  final UpdateService svc;

  @override
  Widget build(BuildContext context) {
    final mandatory = svc.mandatory;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _NoticeBox(
          icon: Icons.check_circle_outline_rounded,
          color: _gold,
          title: 'Download complete',
          text: 'The update is ready. Tap Install to finish updating.',
        ),
        const SizedBox(height: 18),
        _PrimaryButton(
          label: 'Install',
          icon: Icons.system_update_alt_rounded,
          onTap: svc.retry,
        ),
        if (!mandatory) ...[
          const SizedBox(height: 10),
          _SecondaryButton(label: 'Later', onTap: svc.dismissLater),
        ],
      ],
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.svc});

  final UpdateService svc;

  @override
  Widget build(BuildContext context) {
    final mandatory = svc.mandatory;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _NoticeBox(
          icon: Icons.error_outline_rounded,
          color: Colors.redAccent,
          title: "Couldn't update",
          text: svc.errorMessage ?? 'Something went wrong. Please try again.',
        ),
        const SizedBox(height: 18),
        if (svc.errorRetryable)
          _PrimaryButton(
            label: 'Try again',
            icon: Icons.refresh_rounded,
            onTap: svc.retry,
          ),
        if (!mandatory) ...[
          if (svc.errorRetryable) const SizedBox(height: 10),
          _SecondaryButton(label: 'Close', onTap: svc.dismissLater),
        ] else if (!svc.errorRetryable)
          // Mandatory and nothing to retry: keep a way out so the popup
          // can never be a dead end.
          _SecondaryButton(label: 'Exit', onTap: svc.exitApp),
      ],
    );
  }
}

// ───────────────────────────── small parts ─────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.isEmpty ? text : text[0].toUpperCase() + text.substring(1).toLowerCase(),
      style: const TextStyle(
        color: Colors.white,
        fontSize: 13,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _NoticeBox extends StatelessWidget {
  const _NoticeBox({
    required this.icon,
    required this.color,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  text,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.onTap, this.icon});

  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Pressable(
        unconstrained: true,
        onTap: onTap,
        child: Container(
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _gold,
            borderRadius: BorderRadius.circular(30),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, color: Colors.black, size: 20),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Pressable(
        unconstrained: true,
        onTap: onTap,
        child: Container(
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: Colors.white.withValues(alpha: 0.20)),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Pressable(
        unconstrained: true,
        onTap: onTap,
        child: Container(
          height: 52,
          alignment: Alignment.center,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
