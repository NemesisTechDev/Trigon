import 'package:flutter/services.dart';

/// Bridges a `content://` URI (an on-device MediaStore song via
/// LocalMusicService, or a file handed to Nemesis through Android's
/// "Open With"/"Play With" via ExternalMediaHandler) to something
/// [LocalCastServer] can actually read bytes from over plain `dart:io`.
///
/// Neither `dart:io`'s `File` nor any part of the Flutter SDK can open a
/// `content://` URI directly — that scheme only means anything to
/// Android's own `ContentResolver`, on the native side. Local playback
/// never had to solve this: media_kit's Android engine has its own
/// native `content://` support built in, used only for *this device's*
/// mpv instance. Serving those same bytes over HTTP to a *different*
/// device (the TV) needs a real, request-driven byte source on the Dart
/// side, which requires bridging into ContentResolver ourselves.
///
/// The trick (the same one several Flutter plugins that resolve
/// `content://` URIs use): ask ContentResolver for a `ParcelFileDescriptor`
/// natively, hand the raw integer fd across the platform channel, and
/// open `/proc/self/fd/<fd>` from Dart — on Android/Linux that path is a
/// live alias for whatever the fd already points at, so `dart:io`'s
/// `File`/`RandomAccessFile` can read (and seek within) it exactly like
/// a normal file, including the `Range` support [LocalCastServer] needs
/// for the TV to seek. The fd has to stay open for exactly as long as
/// something might still read from that path — see [closeContentFd]'s
/// doc comment for the other half of that lifetime.
///
/// **Requires a small native addition this file alone can't make** — the
/// project's `MainActivity.kt` isn't part of this `lib.zip`, so the two
/// methods below (`openContentFd`/`closeContentFd`) need to be added to
/// the existing `com.nemesis.app/external_media` channel's method-call
/// handler (the same one `consumeInitialMedia`/`onExternalMedia` already
/// live on) by hand. See the handoff notes for the exact Kotlin to add.
/// Until that's added, [openContentFd] always resolves to null (caught
/// as [MissingPluginException]/[PlatformException] below) and
/// [LocalCastServer] surfaces a clear "can't cast this" error rather
/// than hanging — it never crashes for lack of the native side existing
/// yet.
class LocalMediaBridge {
  LocalMediaBridge._();
  static final LocalMediaBridge instance = LocalMediaBridge._();

  // Deliberately the *same* channel name ExternalMediaHandler already
  // owns — a MethodChannel is just a named pipe to whatever the native
  // side registered for that name; a second Dart-side MethodChannel
  // object pointed at the same name talks to the exact same native
  // handler without needing to share ExternalMediaHandler's own
  // (private) channel instance.
  static const MethodChannel _channel =
      MethodChannel('com.nemesis.app/external_media');

  /// Returns a raw native file descriptor open for reading [uri], or
  /// null if the native side doesn't have the `openContentFd` handler
  /// yet, the URI can't be opened (permission revoked, file deleted
  /// since it was scanned/picked), or this isn't Android at all.
  ///
  /// The caller owns the returned fd from this point on and must
  /// eventually pass it to [closeContentFd] — nothing here closes it
  /// automatically, since the whole point is to keep it open for as
  /// long as `/proc/self/fd/<fd>` needs to keep resolving to real bytes.
  Future<int?> openContentFd(String uri) async {
    try {
      return await _channel.invokeMethod<int>('openContentFd', {'uri': uri});
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Releases a fd previously returned by [openContentFd]. Safe to call
  /// even if the native handler doesn't exist yet (same
  /// missing-plugin/platform-exception swallow as above) — this is
  /// always a best-effort cleanup call, never something a caller should
  /// have to guard with its own try/catch.
  Future<void> closeContentFd(int fd) async {
    try {
      await _channel.invokeMethod('closeContentFd', {'fd': fd});
    } on MissingPluginException {
      // Nothing to release on this platform/build.
    } on PlatformException {
      // Already gone, or the native side couldn't adopt it — either way
      // there's nothing more this side can do about it.
    }
  }
}
