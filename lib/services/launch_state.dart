import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/main_nav/navigation_controller.dart';

/// How this run of the app started, and the last screen to return to.
///
/// MainActivity keeps the Flutter engine alive while Android only destroys
/// the Activity in the background, so a normal return needs none of this.
/// It is for the one case that can't be avoided: Android killed the whole
/// app process while the app was in the recent apps list, and then
/// recreated it. [restored] is true then (MainActivity reports it), and the
/// app skips the splash animation and goes back to the last tab instead of
/// opening Home after a full splash, the way a normal app comes back.
///
/// A start from the launcher, the Exit button or after swiping the app out
/// of the recent apps list is never "restored": it shows the full splash.
class LaunchState {
  LaunchState._();

  static const MethodChannel _channel = MethodChannel('com.nemesis.app/launch');
  static const String _tabKey = 'launch.last_nav_tab';

  /// True when Android recreated the app after killing its process.
  static bool restored = false;

  /// Asks MainActivity how the app was started. Never throws.
  static Future<void> init() async {
    try {
      final value = await _channel
          .invokeMethod<bool>('wasRestored')
          .timeout(const Duration(seconds: 2));
      restored = value ?? false;
    } catch (_) {
      restored = false;
    }
  }

  /// Remembers the selected bottom-nav tab so a [restored] start can return
  /// to it. Call once at startup.
  static void trackTab() {
    NavigationController.instance.addListener(() {
      final index = NavigationController.instance.tabIndex;
      SharedPreferences.getInstance()
          .then((prefs) => prefs.setInt(_tabKey, index))
          .catchError((Object _) => false);
    });
  }

  /// On a [restored] start, selects the last tab before the main screen is
  /// built. Does nothing otherwise.
  static Future<void> restoreTab() async {
    if (!restored) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final index = prefs.getInt(_tabKey);
      if (index != null && index >= NavTabs.home && index <= NavTabs.profile) {
        NavigationController.instance.tabIndex = index;
      }
    } catch (_) {}
  }
}
