import 'package:flutter/material.dart';

import '../../screens/live_tv/live_tv_detail_screen.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../utils/epg_utils.dart';
import '../shared/nemesis_bottom_sheet.dart';

/// Shows the "what's on" detail sheet for a single guide program.
///
/// This used to live as a method on a per-tile `GuideProgramTile` widget,
/// one instance of which was built for every program in a channel's
/// fetched window (often 40-60 per row for a full day) regardless of
/// whether it was actually on screen — that per-tile widget/layout cost
/// was the biggest remaining source of the guide's scroll stutter. The
/// grid now paints all of a row's programs in one [CustomPainter] pass
/// (see `_ProgramTilesPainter` in tv_guide_screen.dart) and calls this
/// function directly on tap instead.
void showProgramDetailsSheet(
  BuildContext context,
  Map<String, dynamic> program,
  bool isLive,
) {
  // Same chrome as the video player's Info sheet (see
  // showNemesisBottomSheet's doc comment) — rounded top corners, drag
  // handle, drag up/down to resize, tap-outside/back-gesture/drag-down
  // to close.
  showNemesisBottomSheet<void>(
    context,
    initialChildSize: 0.5,
    minChildSize: 0.28,
    maxChildSize: 0.9,
    builder: (sheetContext, scrollController) => ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        const NemesisSheetDragHandle(bottomMargin: 14),
        if (isLive)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'LIVE',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ),
          if (isLive) const SizedBox(height: 12),
          Text(
            program['Name']?.toString() ?? '',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${EpgUtils.formatTime(program['StartDate'])} - '
            '${EpgUtils.formatTime(program['EndDate'])}',
            style: const TextStyle(color: Colors.white60),
          ),
          const SizedBox(height: 20),
          _ProgramOverview(programId: program['Id']?.toString()),
          const SizedBox(height: 25),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () {
                Navigator.pop(sheetContext);
                final channelId = program['ChannelId']?.toString();
                if (channelId == null || channelId.isEmpty) return;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LiveTvDetailScreen(channelId: channelId),
                  ),
                );
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('Watch Live'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xffD4AF37),
                foregroundColor: Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
}

/// The guide's bulk fetch deliberately omits "Overview" (it's the biggest
/// contributor to payload/parse time across thousands of programs, and is
/// only ever needed for the one program the user actually opens) — so it's
/// fetched here on demand, once, only when this sheet is shown.
class _ProgramOverview extends StatefulWidget {
  const _ProgramOverview({required this.programId});

  final String? programId;

  @override
  State<_ProgramOverview> createState() => _ProgramOverviewState();
}

class _ProgramOverviewState extends State<_ProgramOverview> {
  static const _empty = Text(
    'No description available.',
    style: TextStyle(color: Colors.white70, height: 1.6),
  );

  Future<Map<String, dynamic>>? _future;

  @override
  void initState() {
    super.initState();
    _startFetch();
  }

  @override
  void didUpdateWidget(_ProgramOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only kick off a new fetch if this sheet is now showing a
    // different program — not on every rebuild the sheet goes through
    // (open/close animation frames, ancestor state changes, etc.).
    // Previously the fetch was started directly inside build(), which
    // meant every one of those incidental rebuilds threw away whatever
    // progress the in-flight request had made and restarted it from
    // scratch — on a sheet that rebuilds several times during its own
    // open transition, that could mean the request never got a chance
    // to actually finish, which is exactly what made this feel like it
    // "takes very long to load."
    if (oldWidget.programId != widget.programId) {
      _startFetch();
    }
  }

  void _startFetch() {
    final id = widget.programId;
    _future = (id == null || id.isEmpty) ? null : MediaService.getItem(id);
  }

  @override
  Widget build(BuildContext context) {
    final future = _future;
    if (future == null) return _empty;

    return FutureBuilder<Map<String, dynamic>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xffD4AF37),
              ),
            ),
          );
        }
        final overview = snapshot.data?['Overview']?.toString();
        if (overview == null || overview.isEmpty) return _empty;
        return Text(
          overview,
          style: const TextStyle(color: Colors.white70, height: 1.6),
        );
      },
    );
  }
}
