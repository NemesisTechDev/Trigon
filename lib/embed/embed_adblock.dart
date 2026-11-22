import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Ad blocker for the Embed servers' web player — and only that player.
///
/// The native side (android/.../EmbedAdBlocker.kt) puts a request filter on
/// the ONE WebView [EmbedPlayerScreen] creates. Every script / frame / image
/// that WebView would load from an ad host (the AdGuard DNS filter, the same
/// list dns.adguard.com uses, plus a built-in list of big ad networks) is
/// refused before it leaves the phone. The rest of the app (TMDB, Jellyfin,
/// addons, the native player, trailers, sign-in) is never filtered.
///
/// Android only (the embed player is Android/iOS; iOS has no hook for this in
/// webview_flutter, so there it does nothing).
class EmbedAdBlock {
  EmbedAdBlock._();

  static const MethodChannel _channel =
      MethodChannel('com.nemesis.app/embed_adblock');

  /// Turns the blocker on for [controller]'s WebView. Safe to call more than
  /// once for the same WebView. Returns whether the filter is in place; a
  /// false result only means ads aren't filtered, playback is unaffected.
  static Future<bool> install(
    WebViewController controller, {
    required bool enabled,
  }) async {
    if (!enabled || !Platform.isAndroid) return false;
    try {
      final platform = controller.platform;
      if (platform is! AndroidWebViewController) return false;
      final ok = await _channel.invokeMethod<bool>('install', {
        'webViewId': platform.webViewIdentifier,
        'enabled': enabled,
      });
      return ok ?? false;
    } catch (e) {
      assert(() {
        debugPrint('EmbedAdBlock install failed: $e');
        return true;
      }());
      return false;
    }
  }

  /// How many requests the blocker has refused since the app started
  /// (handy for a debug check that it works).
  static Future<int> blockedCount() async {
    if (!Platform.isAndroid) return 0;
    try {
      return await _channel.invokeMethod<int>('blockedCount') ?? 0;
    } catch (_) {
      return 0;
    }
  }
}
