import 'package:flutter/material.dart';

import '../../../services/external_metadata/trailer_service.dart';
import 'trailer_card.dart';

/// Horizontal, single-row rendering of a title's trailers/teasers —
/// same shape as EpisodeRow, just backed by TrailerInfo instead of
/// Jellyfin episode maps. Used identically by TrailerSheet in both
/// portrait and landscape.
class TrailerRow extends StatelessWidget {
  final List<TrailerInfo> trailers;
  final bool loading;
  final ValueChanged<TrailerInfo> onSelect;

  const TrailerRow({
    super.key,
    required this.trailers,
    required this.loading,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (trailers.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 30),
        child: Center(
          child: Text(
            "No trailers available",
            style: TextStyle(color: Colors.white54, fontSize: 16),
          ),
        ),
      );
    }

    return SizedBox(
      height: 200,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        scrollDirection: Axis.horizontal,
        itemCount: trailers.length,
        separatorBuilder: (_, __) => const SizedBox(width: 16),
        itemBuilder: (context, index) {
          final trailer = trailers[index];
          return TrailerCard(
            trailer: trailer,
            onTap: () => onSelect(trailer),
          );
        },
      ),
    );
  }
}
