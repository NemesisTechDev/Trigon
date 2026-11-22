import '../player/models/media_item.dart';

/// Thrown for a local item this transport genuinely cannot cast — an
/// unsupported container/codec with no server around to transcode it, or
/// no way to reach the file's bytes at all. A distinct type (rather than
/// a bare StateError) so callers that want to can show the real reason
/// instead of a generic "couldn't reach the device" message —
/// PlaybackCoordinator's cast-handoff failure handlers do exactly that.
class LocalCastUnsupportedException implements Exception {
  LocalCastUnsupportedException(this.message);
  final String message;
  @override
  String toString() => message;
}

const Map<String, String> _localAudioMimeByExtension = {
  'mp3': 'audio/mpeg',
  'aac': 'audio/aac',
  'm4a': 'audio/mp4',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'opus': 'audio/ogg',
  // CORRECTION: previously treated as unsupported here on the assumption
  // that an "exotic" lossless format would need transcoding, with no
  // actual source checked. Google's own Supported Media for Google Cast
  // page lists FLAC (up to 96kHz/24-bit) as a natively supported audio
  // codec on the stock Default Media Receiver — the same receiver
  // Chromecast Audio, Google Home, and Nest speakers already use.
  //
  // Worth flagging rather than treating as settled either way: this same
  // file has a real prior fix (GoogleCastTransport._resolveCastMedia,
  // search "CASTING FIX (FLAC never played)") for *Jellyfin-hosted* FLAC
  // — added after FLAC was empirically observed not to play on the
  // actual receiver being tested against, despite being on Google's
  // documented codec list, and redirected to server transcoding rather
  // than trusting the docs. That fix has no local equivalent (there's no
  // server to transcode a file that only lives on this phone), so a
  // local FLAC file now goes out with a plain `audio/flac` Content-Type
  // and no such safety net. If it turns out to have the same real-world
  // playback problem the Jellyfin one did, there's no way to route
  // around it the way the Jellyfin case was — it would mean genuinely
  // adding FLAC back to the unsupported list here, not another retry.
  'flac': 'audio/flac',
};

const Map<String, String> _localVideoMimeByExtension = {
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'webm': 'video/webm',
  'ts': 'video/mp2t',
  'm2ts': 'video/mp2t',
  // CORRECTION (superseded again — read this before touching MKV here a
  // third time): this used to declare MKV supported outright, pointing
  // at GoogleCastTransport's old "REVERTED" note as evidence real
  // devices direct-stream MKV movie/TV files fine. That note itself
  // turned out to be based on a since-fixed bug (an unrelated hardcode
  // was mislabeling MKV bytes as `video/mp4`, which happened to let them
  // through) — see its replacement, the "CONTAINER HISTORY" note above
  // `GoogleCastTransport._needsContainerTranscodeForCast`. Google's
  // Default Media Receiver genuinely has no Matroska demuxer
  // (https://developers.google.com/cast/docs/media lists MP2T/MP3/MP4/
  // OGG/WAV/WebM only).
  //
  // `video/x-matroska` stays mapped here — still the real, correct MIME
  // type for the container, and still needed so
  // `LocalCastServer.registerMedia` can recognize "this is an MKV" at
  // all — but a local MKV file no longer actually goes out over the
  // wire under this Content-Type: `registerMedia` remuxes it into
  // MPEG-TS first, on-device, via `LocalVideoTranscodeService` (the
  // no-Jellyfin-server equivalent of `GoogleCastTransport`'s HLS remux
  // fix for a server-hosted MKV — see `MediaService
  // .getVideoCastTranscodeUrl`'s doc comment for that server-side
  // version of the same fix). Android-only for now, and stream-copy
  // only: see `LocalVideoTranscodeService`'s own doc comment for why a
  // local file whose actual codec isn't Cast-compatible (not just its
  // container) still fails outright rather than being re-encoded.
  'mkv': 'video/x-matroska',
};

const Map<String, String> _mimeTypeToExtension = {
  'video/mp4': 'mp4',
  'video/webm': 'webm',
  'video/mp2t': 'ts',
  'video/x-matroska': 'mkv',
  'audio/mpeg': 'mp3',
  'audio/mp4': 'm4a',
  'audio/aac': 'aac',
  'audio/wav': 'wav',
  'audio/x-wav': 'wav',
  'audio/ogg': 'ogg',
  'audio/flac': 'flac',
  'audio/x-flac': 'flac',
  // Provider-reported types an Open With file commonly carries (a bare
  // `content://` URI has no extension to read, so the MIME type the
  // sharing app reported is the only trustworthy hint). Only used to NAME
  // the container; whether a given cast target can play it is decided
  // elsewhere.
  'video/x-m4v': 'm4v',
  'video/avi': 'avi',
  'video/x-msvideo': 'avi',
  'video/quicktime': 'mov',
  'video/mpeg': 'mpg',
  'video/3gpp': '3gp',
  'video/3gpp2': '3g2',
  'video/x-ms-wmv': 'wmv',
  'video/x-ms-asf': 'asf',
  'video/x-flv': 'flv',
  'video/ogg': 'ogv',
  'audio/mp3': 'mp3',
  'audio/x-mp3': 'mp3',
  'audio/x-m4a': 'm4a',
  'audio/m4a': 'm4a',
  'audio/opus': 'opus',
  'audio/x-ms-wma': 'wma',
  'audio/aiff': 'aif',
  'audio/x-aiff': 'aif',
  'audio/x-matroska': 'mka',
};

/// The real container [item] is stored in, best-effort: prefers
/// LocalMusicService's own `FileExtension` (read straight off
/// MediaStore's `DATA` column — a `content://` URI alone has no
/// extension of its own to read; see that field's own doc comment),
/// falls back to ExternalMediaHandler's provider-reported `MimeType`
/// (an Open With file very often has no extension of its own either —
/// a bare `content://` share from another app's FileProvider), and only
/// then falls back to whatever extension happens to be on the source
/// URI/path itself (present for a `file://` path, essentially never for
/// a MediaStore `content://` URI).
String localFileExtension(MediaItem item) {
  // Set by CastManager for an addon link once the real container is known
  // (read from the link's first bytes), so every transport agrees with what
  // is actually relayed.
  final resolved = item.raw?['CastResolvedExtension']?.toString();
  if (resolved != null && resolved.isNotEmpty) return resolved.toLowerCase();

  final fromScan = item.raw?['FileExtension']?.toString();
  if (fromScan != null && fromScan.isNotEmpty) return fromScan.toLowerCase();

  final mime = item.raw?['MimeType']?.toString().toLowerCase();
  if (mime != null && mime.isNotEmpty) {
    final mapped = _mimeTypeToExtension[mime];
    if (mapped != null) return mapped;
  }

  // ROOT CAUSE (an Open With / provider file never casts, on any DLNA TV):
  // this used to take whatever followed the LAST '.' anywhere in the URI.
  // A `content://` URI has no file extension, but its AUTHORITY does have
  // dots (`content://com.android.providers.downloads.documents/...`), so
  // the "extension" came out as `android.providers.downloads.documents/...`
  // — which no format table knows — and the cast was refused as an
  // "unrecognised format" before the TV was even contacted. Only the last
  // path segment is looked at now, and only a plausible extension
  // (1-5 letters/digits) is accepted; anything else means "unknown".
  final url = item.streamUrl;
  String lastSegment = url;
  final parsed = Uri.tryParse(url);
  if (parsed != null && parsed.pathSegments.isNotEmpty) {
    lastSegment = parsed.pathSegments.last;
  }
  final dot = lastSegment.lastIndexOf('.');
  if (dot >= 0 && dot < lastSegment.length - 1) {
    final ext = lastSegment.substring(dot + 1).toLowerCase();
    if (RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext)) return ext;
  }
  return '';
}

/// Resolves the container/mime [item] should be declared as to Cast, or
/// throws [LocalCastUnsupportedException] up front for a format the
/// stock Cast Default Media Receiver genuinely can't open at all (an
/// AVI video, or an exotic audio codec — FLAC, mp3/aac/wav/ogg/opus are
/// all supported directly, see the mime maps above; MKV video is
/// supported too, but only after `LocalCastServer.registerMedia` remuxes
/// it on-device first — see the `mkv` map entry's own comment). There's
/// no Jellyfin server around to transcode a file that only ever existed
/// on this phone the way a real Jellyfin item can (see
/// GoogleCastTransport._needsTranscodeForCast), which is exactly why
/// that on-device remux step exists. Used by both
/// CastManager (to know what to tell LocalCastServer to declare in its
/// Content-Type header) and GoogleCastTransport (to know what to declare
/// to the Cast SDK itself) — the two have to agree, so this is the one
/// place that decides for both.
({String contentType, String extension}) resolveLocalCastFormat(
  MediaItem item,
) {
  final ext = localFileExtension(item);

  if (item.audioOnly) {
    final mime = _localAudioMimeByExtension[ext];
    if (mime == null) {
      throw LocalCastUnsupportedException(
        '"${item.title}"${ext.isEmpty ? '' : ' (.$ext)'} can\'t be cast — '
        'the TV\'s built-in Cast player doesn\'t support this audio '
        'format directly.',
      );
    }
    return (contentType: mime, extension: ext);
  }

  final mime = _localVideoMimeByExtension[ext];
  if (mime == null) {
    throw LocalCastUnsupportedException(
      '"${item.title}"${ext.isEmpty ? '' : ' (.$ext)'} can\'t be cast — '
      'the TV\'s built-in Cast player only plays MP4/M4V/WebM/MKV/TS '
      'directly, and there\'s no Jellyfin server to transcode a file '
      'that only exists on this device.',
    );
  }
  return (contentType: mime, extension: ext);
}

/// DLNA/UPnP counterpart of [resolveLocalCastFormat].
///
/// A DLNA renderer (LG webOS, Samsung Tizen, Sony, Philips …) decodes in
/// its own firmware rather than in Google's Default Media Receiver, so the
/// set of containers it will play is much wider — MKV, AVI, MOV, WMV, MPEG,
/// TS, FLAC, WMA all play natively on most of them — and, crucially, MKV
/// needs **no** on-device remux. The TV is the one that decides whether it
/// can play the file; this resolver only needs to *name* the container
/// correctly for the HTTP `Content-Type` header and the DIDL `protocolInfo`.
///
/// An unknown or missing extension (a `content://` URI with no suffix) is
/// not refused: it's declared as generic MP4/MP3 and the TV sniffs the real
/// container from the bytes, which every DLNA renderer already does.
const Map<String, String> _dlnaExtraVideoMime = {
  'avi': 'video/x-msvideo',
  'wmv': 'video/x-ms-wmv',
  'asf': 'video/x-ms-asf',
  'mpg': 'video/mpeg',
  'mpeg': 'video/mpeg',
  'mpe': 'video/mpeg',
  'vob': 'video/mpeg',
  'm2ts': 'video/mp2t',
  'mts': 'video/mp2t',
  'ts': 'video/mp2t',
  'mov': 'video/quicktime',
  '3gp': 'video/3gpp',
  '3g2': 'video/3gpp2',
  'flv': 'video/x-flv',
  'ogv': 'video/ogg',
};

const Map<String, String> _dlnaExtraAudioMime = {
  'wma': 'audio/x-ms-wma',
  'aif': 'audio/aiff',
  'aiff': 'audio/aiff',
  'alac': 'audio/mp4',
  'ape': 'audio/x-ape',
  'mka': 'audio/x-matroska',
  'opus': 'audio/ogg',
  'oga': 'audio/ogg',
  'm4b': 'audio/mp4',
  'mp2': 'audio/mpeg',
};

({String contentType, String extension}) resolveLocalDlnaFormat(
  MediaItem item,
) {
  final ext = localFileExtension(item);

  // The MIME type the file's provider reported (Open With). Used when the
  // extension is missing or unknown, so such a file is declared as what it
  // really is instead of being guessed as MP4/MP3.
  final reported = (item.raw?['CastResolvedMimeType'] ?? item.raw?['MimeType'])
      ?.toString()
      .toLowerCase()
      .trim();

  if (item.audioOnly) {
    final mime = _localAudioMimeByExtension[ext] ??
        _dlnaExtraAudioMime[ext] ??
        ((reported != null && reported.startsWith('audio/'))
            ? reported
            : null) ??
        (ext.isEmpty ? 'audio/mpeg' : null);
    if (mime == null) {
      throw LocalCastUnsupportedException(
        '\"${item.title}\" (.$ext) can\'t be sent to a DLNA TV — '
        'unrecognised audio format.',
      );
    }
    // The served URL always ends in a real extension: many TV firmwares
    // choose their demuxer from it.
    return (
      contentType: mime,
      extension: ext.isNotEmpty ? ext : (_mimeTypeToExtension[mime] ?? 'mp3'),
    );
  }

  final mime = _localVideoMimeByExtension[ext] ??
      _dlnaExtraVideoMime[ext] ??
      ((reported != null && reported.startsWith('video/'))
          ? reported
          : null) ??
      (ext.isEmpty ? 'video/mp4' : null);
  if (mime == null) {
    throw LocalCastUnsupportedException(
      '\"${item.title}\" (.$ext) can\'t be sent to a DLNA TV — '
      'unrecognised video format.',
    );
  }
  return (
    contentType: mime,
    extension: ext.isNotEmpty ? ext : (_mimeTypeToExtension[mime] ?? 'mp4'),
  );
}
