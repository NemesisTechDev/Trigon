import 'package:flutter/material.dart';

import '../../services/download_manager.dart';
import '../../services/storage_stats_service.dart';

const _gold = Color(0xffD4AF37);

/// Formats bytes as a human-readable size string (matches the precision
/// premium apps like Netflix/Spotify use in their downloads/storage
/// screens).
String formatBytes(num bytes) {
  if (bytes <= 0) return "0 MB";
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;

  if (bytes >= gb) return "${(bytes / gb).toStringAsFixed(1)} GB";
  if (bytes >= mb) return "${(bytes / mb).toStringAsFixed(0)} MB";
  return "${(bytes / kb).toStringAsFixed(0)} KB";
}

/// Storage section card for Settings: a single gold bar showing how
/// much of the *device's* total storage is in use (across every app,
/// not just Nemesis) against how much is free, followed by a
/// breakdown row per category — Other Apps, App Data, Downloads,
/// Cache, Free — each with its own size. Downloads and the live
/// device-total figures fold in [DownloadManager.totalBytes] via
/// [AnimatedBuilder], so deleting a download while this card is on
/// screen updates it immediately without a full rescan.
class StorageUsageCard extends StatefulWidget {
  const StorageUsageCard({super.key});

  @override
  State<StorageUsageCard> createState() => StorageUsageCardState();
}

class StorageUsageCardState extends State<StorageUsageCard> {
  StorageBreakdown? _breakdown;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final breakdown = await StorageStatsService.compute();
    if (!mounted) return;
    setState(() {
      _breakdown = breakdown;
      _loading = false;
    });
  }

  /// Called by the Storage section after "Clear Cache" or "Remove All
  /// Downloads" finishes, so this card's numbers reflect the freed
  /// space right away instead of showing stale pre-clear totals until
  /// Settings is reopened.
  Future<void> refresh() => _load();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: DownloadManager.instance,
      builder: (context, _) {
        final breakdown = _breakdown;
        final downloadsBytes = DownloadManager.instance.totalBytes;

        final totalDevice = breakdown?.totalDeviceBytes;
        final freeDevice = breakdown?.freeDeviceBytes;
        final otherAppsBytes = breakdown?.otherAppsBytes(downloadsBytes);

        // .toDouble() matters here: num.clamp() is statically typed to
        // return num, not double, even when called on a double
        // receiver — without it this is a num?, and
        // FractionallySizedBox.widthFactor below requires a double.
        final usedFraction = (totalDevice != null &&
                totalDevice > 0 &&
                freeDevice != null)
            ? ((totalDevice - freeDevice) / totalDevice)
                .clamp(0.0, 1.0)
                .toDouble()
            : null;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: const Color(0xff1F1F1F),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(.06)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Storage summary",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _loading
                    ? "Calculating…"
                    : (totalDevice != null && freeDevice != null)
                        ? "${formatBytes(totalDevice - freeDevice)} used of ${formatBytes(totalDevice)} on this device"
                        : "Device storage unavailable",
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 10,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: Container(color: Colors.white.withOpacity(.08)),
                    ),
                    if (usedFraction != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: usedFraction,
                          heightFactor: 1,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(5),
                            child: Container(color: _gold),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(height: 1, color: Colors.white.withOpacity(.06)),
              const SizedBox(height: 12),
              _StorageBreakdownRow(
                label: "Other Apps",
                bytes: otherAppsBytes,
                loading: _loading,
                dotColor: Colors.white,
                dotOpacity: .7,
              ),
              const SizedBox(height: 10),
              _StorageBreakdownRow(
                label: "App Data",
                bytes: breakdown?.appDataBytes,
                loading: _loading,
                dotColor: _gold,
                dotOpacity: 1,
              ),
              const SizedBox(height: 10),
              _StorageBreakdownRow(
                label: "Downloads",
                bytes: downloadsBytes,
                loading: _loading,
                dotColor: _gold,
                dotOpacity: .65,
              ),
              const SizedBox(height: 10),
              _StorageBreakdownRow(
                label: "Cache",
                bytes: breakdown?.cacheBytes,
                loading: _loading,
                dotColor: _gold,
                dotOpacity: .35,
              ),
              const SizedBox(height: 10),
              _StorageBreakdownRow(
                label: "Free",
                bytes: freeDevice?.round(),
                loading: _loading,
                dotColor: Colors.white,
                dotOpacity: .24,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StorageBreakdownRow extends StatelessWidget {
  final String label;
  final int? bytes;
  final bool loading;
  final Color dotColor;
  final double dotOpacity;

  const _StorageBreakdownRow({
    required this.label,
    required this.bytes,
    required this.loading,
    required this.dotColor,
    this.dotOpacity = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: dotColor.withOpacity(dotOpacity),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
        Text(
          loading ? "—" : formatBytes(bytes ?? 0),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
