import 'package:flutter/material.dart';

import '../../../library/watch_history_service.dart';
import '../../../services/favorite_service.dart';
import '../../../virtual/virtual_catalog.dart';
import '../../../widgets/music/song_multi_select.dart';

/// Favorite state of a Movie/Series item id: true / false when it can be
/// favorited, null when it can't (collections, people, anything that
/// isn't a movie or a series). Null items are never selectable.
bool? titleFavoriteState(String id) {
  final v = VId.parse(id);
  if (v.kind != 'movie' && v.kind != 'series') return null;
  final key = '${v.kind == 'movie' ? 'movie' : 'tv'}:${v.tmdbId}';
  return WatchHistoryService.instance.watchlist.value
      .any((s) => s.key == key);
}

/// True when every selected title is already a favorite.
bool selectionAllFavorited(SongMultiSelect selection) =>
    selection.active &&
    selection.selectedIds.every((id) => titleFavoriteState(id) == true);

/// The one bulk action for a movie / TV show selection. If every selected
/// title is already a favorite they are all removed from Favorites,
/// otherwise all of them are added. Titles that fail stay selected so the
/// action can simply be retried; the rest leave the selection.
///
/// [setState] is the calling State's own setState.
Future<void> toggleFavoriteForSelection({
  required BuildContext context,
  required SongMultiSelect selection,
  required void Function(VoidCallback fn) setState,
}) async {
  if (selection.busy || !selection.active) return;

  final ids = selection.selectedIds.toList();
  final makeFavorite = !selectionAllFavorited(selection);
  final messenger = ScaffoldMessenger.maybeOf(context);

  setState(() => selection.busy = true);

  final succeeded = <String>[];
  var failed = 0;

  // One at a time: each toggle rewrites the saved favorites list.
  for (final id in ids) {
    if (titleFavoriteState(id) != makeFavorite) {
      try {
        await VirtualCatalog.setFavorite(id, makeFavorite);
      } catch (_) {}
    }
    if (titleFavoriteState(id) == makeFavorite) {
      succeeded.add(id);
    } else {
      failed++;
    }
  }

  FavoriteService.notifyChanged();

  if (context.mounted) {
    setState(() {
      selection.selectedIds.removeAll(succeeded);
      selection.busy = false;
    });
  }

  final n = succeeded.length;
  final noun = n == 1 ? 'title' : 'titles';
  final String message;
  if (failed > 0) {
    message = n == 0
        ? "Couldn't update favorites. Try again."
        : (makeFavorite
            ? "Added $n $noun to Favorites. $failed couldn't be updated."
            : "Removed $n $noun from Favorites. $failed couldn't be updated.");
  } else {
    message = makeFavorite
        ? "Added $n $noun to Favorites"
        : "Removed $n $noun from Favorites";
  }

  messenger?.showSnackBar(SnackBar(
    content: Text(message),
    behavior: SnackBarBehavior.floating,
    duration: const Duration(seconds: 2),
  ));
}
