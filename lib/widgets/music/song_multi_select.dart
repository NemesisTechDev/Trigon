/// Tiny helper bundling the "long-press to multi-select songs" state a
/// screen needs — which song ids are currently selected, and whether a
/// bulk action is in flight. Deliberately not a ChangeNotifier: every
/// screen using this already owns a setState() of its own (same as the
/// existing playlist-selection fields in MusicScreen), so mutating this
/// object's fields inside that same setState call is all that's needed
/// instead of juggling a second listenable.
class SongMultiSelect {
  final Set<String> selectedIds = {};
  bool busy = false;

  bool get active => selectedIds.isNotEmpty;

  int get count => selectedIds.length;

  bool isSelected(String id) => selectedIds.contains(id);

  /// Long-press on a row when nothing is selected yet — starts a fresh
  /// selection containing just that row.
  void enter(String id) {
    selectedIds
      ..clear()
      ..add(id);
  }

  /// Tap on a row while selection is already active — adds or removes
  /// just that row.
  void toggle(String id) {
    if (!selectedIds.remove(id)) selectedIds.add(id);
  }

  void clear() {
    selectedIds.clear();
    busy = false;
  }
}
