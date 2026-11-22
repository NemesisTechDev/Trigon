import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../player/models/subtitle_appearance.dart';

/// In-memory, synchronously-readable home of the user's subtitle style.
/// Same pattern as [AppSettings]: loaded once at startup, and every
/// consumer (the video overlay, the settings preview, the casting sync)
/// just listens to [notifier] — so a change made in Settings applies to
/// the player *and* the TV the instant it happens.
class SubtitleAppearanceSettings {
  SubtitleAppearanceSettings._();

  static const _prefsKey = 'subtitle_appearance_v1';

  static final ValueNotifier<SubtitleAppearance> notifier =
      ValueNotifier(SubtitleAppearance.defaults);

  static Timer? _persistTimer;

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = SubtitleAppearance.tryDecode(prefs.getString(_prefsKey));
      if (stored != null) notifier.value = stored;
    } catch (e) {
      debugPrint('SubtitleAppearanceSettings.load failed: $e');
    }
  }

  /// Applies immediately (listeners update this frame), persists after a
  /// short debounce so dragging a slider doesn't hammer disk.
  static void update(SubtitleAppearance value) {
    if (value == notifier.value) return;
    notifier.value = value;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 300), _persist);
  }

  static void reset() => update(SubtitleAppearance.defaults);

  static Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = notifier.value;
      if (value.isDefault) {
        await prefs.remove(_prefsKey);
      } else {
        await prefs.setString(_prefsKey, value.encode());
      }
    } catch (e) {
      debugPrint('SubtitleAppearanceSettings persist failed: $e');
    }
  }
}
