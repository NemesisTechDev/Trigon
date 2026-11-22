import 'dart:async';

import 'package:flutter/material.dart';

import '../../addons/addon_client.dart';
import '../../addons/addon_manager.dart';
import '../../addons/addon_models.dart';
import '../../catalog/catalog_models.dart';
import '../../library/source_preferences.dart';
import '../addons/addons_screen.dart';

/// "Choose a source" bottom sheet — the Stremio-style stream list.
///
/// Asks every installed addon for streams and shows results as they arrive.
/// Pops with the chosen [AddonStream], or null if dismissed.
class StreamPickerSheet extends StatefulWidget {
  final CatalogTitle title;
  final CatalogEpisode? episode;

  const StreamPickerSheet({super.key, required this.title, this.episode});

  static Future<AddonStream?> show(
    BuildContext context, {
    required CatalogTitle title,
    CatalogEpisode? episode,
  }) {
    return showModalBottomSheet<AddonStream>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C1C1C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => StreamPickerSheet(title: title, episode: episode),
    );
  }

  @override
  State<StreamPickerSheet> createState() => _StreamPickerSheetState();
}

class _StreamPickerSheetState extends State<StreamPickerSheet> {
  static const Color _gold = Color(0xFFD4AF37);

  late final Stream<List<AddonStream>> _stream;
  SourcePreference? _pref;

  /// Link type ("Direct link" / "Torrent") of the selected chip, or null for
  /// "All".
  String? _addonFilter;

  @override
  void initState() {
    super.initState();
    final e = widget.episode;
    final id = e != null
        ? widget.title.addonId(season: e.season, episode: e.number)
        : widget.title.addonId();
    AddonClient.torrentOnlyCount = 0;
    AddonClient.failedStreamRequests = 0;
    // Created once here, not in build(), or every rebuild would re-query
    // every addon.
    _stream = AddonManager.instance.watchStreams(widget.title.type.addon, id);
    _loadPref();
  }

  Future<void> _loadPref() async {
    await SourcePreferences.instance.load();
    if (!mounted) return;
    setState(() {
      _pref = SourcePreferences.instance
          .forTitle('${widget.title.type.tmdb}:${widget.title.tmdbId}');
    });
  }

  /// Moves the previously used source (if offered) to the top.
  List<AddonStream> _ordered(List<AddonStream> streams) {
    final p = _pref;
    if (p == null) return streams;
    final i = streams.indexWhere(p.matches);
    if (i <= 0) return streams;
    return [streams[i], ...streams.take(i), ...streams.skip(i + 1)];
  }

  /// Why the list is empty, from what the addons actually answered.
  String _emptyReason() {
    final torrents = AddonClient.torrentOnlyCount;
    final failed = AddonClient.failedStreamRequests;
    final parts = <String>[
      'None of your addons returned a playable source for this title.',
    ];
    if (torrents > 0) {
      parts.add('$torrents result${torrents == 1 ? '' : 's'} used a '
          'torrent format this app could not read (no valid info hash).');
    }
    if (failed > 0) {
      parts.add('$failed addon request${failed == 1 ? '' : 's'} failed or '
          'timed out. Check the addon address and your connection.');
    }
    return parts.join('\n\n');
  }

  /// One chip per link type that returned links ("Direct link", "Torrent"),
  /// preceded by "All". Hidden when only one type is present. Addon names are
  /// never shown.
  Widget _chips(List<AddonStream> all, String? selected) {
    final names = <String, String>{};
    final counts = <String, int>{};
    for (final s in all) {
      names.putIfAbsent(s.typeLabel, () => s.typeLabel);
      counts[s.typeLabel] = (counts[s.typeLabel] ?? 0) + 1;
    }
    if (names.length < 2) return const SizedBox.shrink();

    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        children: [
          _chip(
            label: 'All',
            count: all.length,
            selected: selected == null,
            onTap: () => setState(() => _addonFilter = null),
          ),
          for (final entry in names.entries)
            _chip(
              label: entry.value,
              count: counts[entry.key] ?? 0,
              selected: selected == entry.key,
              onTap: () => setState(() => _addonFilter = entry.key),
            ),
        ],
      ),
    );
  }

  Widget _chip({
    required String label,
    required int count,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text('$label · $count'),
        selected: selected,
        showCheckmark: false,
        onSelected: (_) => onTap(),
        selectedColor: _gold.withValues(alpha: 0.22),
        backgroundColor: Colors.white10,
        side: BorderSide(color: selected ? _gold : Colors.white12),
        labelStyle: TextStyle(
          color: selected ? _gold : Colors.white70,
          fontWeight: FontWeight.w600,
          fontSize: 12.5,
        ),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.episode;
    final heading = e == null
        ? widget.title.title
        : '${widget.title.title} · S${e.season}E${e.number}';

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                'Choose a source',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                heading,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ),
            Flexible(
              child: ValueListenableBuilder<List<AddonManifest>>(
                valueListenable: AddonManager.instance.addons,
                builder: (context, installed, _) {
                  if (!AddonManager.instance.hasStreamAddons) {
                    return _NoAddons(onAdd: () async {
                      await Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => const AddonsScreen(),
                      ));
                    });
                  }
                  return StreamBuilder<List<AddonStream>>(
                    stream: _stream,
                    initialData: const [],
                    builder: (context, snap) {
                      final all = _ordered(snap.data ?? const []);
                      final done = snap.connectionState == ConnectionState.done;

                      if (all.isEmpty) {
                        return done
                            ? _Message(
                                icon: Icons.search_off_rounded,
                                text: _emptyReason(),
                              )
                            : const Padding(
                                padding: EdgeInsets.all(32),
                                child: Center(
                                  child: CircularProgressIndicator(
                                      color: _gold, strokeWidth: 2.5),
                                ),
                              );
                      }

                      // Fall back to "All" if the selected link type has no
                      // links (anymore).
                      final selected = (_addonFilter != null &&
                              all.any((s) => s.typeLabel == _addonFilter))
                          ? _addonFilter
                          : null;
                      final streams = selected == null
                          ? all
                          : all.where((s) => s.typeLabel == selected).toList();

                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _chips(all, selected),
                          Flexible(
                            child: ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                        itemCount: streams.length + (done ? 0 : 1),
                        separatorBuilder: (_, __) => const Divider(
                            height: 1, color: Colors.white10),
                        itemBuilder: (context, i) {
                          if (i == streams.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 14),
                              child: Center(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      color: _gold, strokeWidth: 2),
                                ),
                              ),
                            );
                          }
                          final s = streams[i];
                          return _StreamTile(
                            stream: s,
                            lastUsed: _pref?.matches(s) ?? false,
                            onTap: () => Navigator.of(context).pop(s),
                          );
                        },
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StreamTile extends StatelessWidget {
  final AddonStream stream;
  final VoidCallback onTap;
  final bool lastUsed;
  const _StreamTile({
    required this.stream,
    required this.onTap,
    this.lastUsed = false,
  });

  @override
  Widget build(BuildContext context) {
    final quality = stream.qualityLabel;
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      leading: Container(
        width: 52,
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFD4AF37).withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          quality.isEmpty ? 'HD' : quality,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFFD4AF37),
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            // The kind of link ("Direct link" / "Torrent"), not the addon's
            // own name.
            child: Text(
              stream.typeLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14),
            ),
          ),
          if (lastUsed) ...[
            const SizedBox(width: 8),
            const Text('LAST USED',
                style: TextStyle(
                    color: Color(0xFFD4AF37),
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6)),
          ],
        ],
      ),
      subtitle: stream.description.isEmpty
          ? null
          : Text(
              stream.description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
      trailing: const Icon(Icons.play_arrow_rounded, color: Colors.white70),
    );
  }
}

class _NoAddons extends StatelessWidget {
  final VoidCallback onAdd;
  const _NoAddons({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.extension_outlined, color: Colors.white38, size: 40),
          const SizedBox(height: 12),
          const Text(
            'No addons installed yet.\nAn addon is what finds something to play.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, height: 1.4),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: onAdd,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD4AF37),
              foregroundColor: Colors.black,
            ),
            child: const Text('Add an addon'),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Message({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white38, size: 40),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, height: 1.4),
          ),
        ],
      ),
    );
  }
}
