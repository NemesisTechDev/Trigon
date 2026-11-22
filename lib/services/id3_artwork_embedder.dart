import 'dart:io';
import 'dart:typed_data';

/// Writes cover art into an MP3 file's ID3v2 tag as an `APIC` (front
/// cover) frame — pure Dart, no extra package.
///
/// WHY THIS EXISTS: a song downloaded at a chosen bitrate is an MP3 the
/// Jellyfin server *encodes on the fly* (`/Audio/{id}/stream.mp3`). That
/// encode carries no embedded picture, so the finished file showed no
/// artwork in a file manager, the Android media library or any other
/// player — even though the app itself had already cached the cover
/// separately (`DownloadRecord.posterPath`). Embedding the cached cover
/// into the file makes a transcoded download look the same as the
/// original MP3 does outside the app.
///
/// Behaviour:
///  * No existing tag → a fresh ID3v2.3 tag holding just the cover.
///  * Existing ID3v2.3 / v2.4 tag → the cover frame is appended to it,
///    every existing frame is carried over byte-for-byte.
///  * Existing tag already has an `APIC` frame → left completely alone
///    (never replaces art the file already has).
///  * Anything unusual (ID3v2.2, unsynchronisation, extended header,
///    unreadable tag) → file untouched, returns false. Never corrupts.
class Id3ArtworkEmbedder {
  Id3ArtworkEmbedder._();

  /// Returns true when the file now has (or already had) embedded art.
  static Future<bool> embed({
    required String mp3Path,
    required String imagePath,
  }) async {
    final mp3 = File(mp3Path);
    final image = File(imagePath);
    if (!await mp3.exists() || !await image.exists()) return false;

    final imageBytes = await image.readAsBytes();
    if (imageBytes.length < 16) return false;
    final mime = _mimeFor(imageBytes);
    if (mime == null) return false;

    final raf = await mp3.open();
    try {
      final head = await raf.read(10);
      var version = 3;
      var audioStart = 0;
      final existingFrames = BytesBuilder(copy: false);

      if (head.length == 10 &&
          head[0] == 0x49 && // I
          head[1] == 0x44 && // D
          head[2] == 0x33) {
        // 3
        version = head[3];
        final flags = head[5];
        // v2.2 uses a different frame layout; unsynchronisation (0x80)
        // and an extended header (0x40) would need re-encoding of the
        // frames we carry over. All rare in practice — skip safely.
        if (version != 3 && version != 4) return false;
        if (flags & 0x80 != 0 || flags & 0x40 != 0) return false;
        final hasFooter = version == 4 && (flags & 0x10) != 0;
        final tagSize = _readSyncsafe(head, 6);
        final tagBytes = await raf.read(tagSize);
        if (tagBytes.length != tagSize) return false;
        audioStart = 10 + tagSize + (hasFooter ? 10 : 0);

        var pos = 0;
        while (pos + 10 <= tagBytes.length) {
          if (tagBytes[pos] == 0) break; // padding reached
          final id = String.fromCharCodes(tagBytes.sublist(pos, pos + 4));
          final size = version == 4
              ? _readSyncsafe(tagBytes, pos + 4)
              : _readUint32(tagBytes, pos + 4);
          final end = pos + 10 + size;
          if (size < 0 || end > tagBytes.length) return false;
          if (id == 'APIC') return true; // already has artwork
          existingFrames.add(tagBytes.sublist(pos, end));
          pos = end;
        }
      }

      final apic = _buildApicFrame(version, mime, imageBytes);
      final frames = BytesBuilder(copy: false)
        ..add(existingFrames.takeBytes())
        ..add(apic);
      final framesBytes = frames.takeBytes();
      // ID3v2 sizes are 28-bit syncsafe.
      if (framesBytes.length >= (1 << 28)) return false;

      final header = Uint8List(10)
        ..[0] = 0x49
        ..[1] = 0x44
        ..[2] = 0x33
        ..[3] = version
        ..[4] = 0
        ..[5] = 0;
      _writeSyncsafe(header, 6, framesBytes.length);

      // Write tag + untouched audio to a sibling temp file, then swap it
      // in, so a failure part-way never leaves a half-written song.
      final tmp = File('$mp3Path.tmp');
      final sink = tmp.openWrite();
      try {
        sink.add(header);
        sink.add(framesBytes);
        await raf.setPosition(audioStart);
        const chunk = 256 * 1024;
        while (true) {
          final buf = await raf.read(chunk);
          if (buf.isEmpty) break;
          sink.add(buf);
        }
        await sink.flush();
        await sink.close();
      } catch (_) {
        try {
          await sink.close();
        } catch (_) {}
        try {
          await tmp.delete();
        } catch (_) {}
        rethrow;
      }
      await raf.close();
      await tmp.rename(mp3Path);
      return true;
    } finally {
      try {
        await raf.close();
      } catch (_) {}
    }
  }

  static Uint8List _buildApicFrame(
    int version,
    String mime,
    Uint8List imageBytes,
  ) {
    final body = BytesBuilder(copy: false)
      ..addByte(0x00) // text encoding: ISO-8859-1
      ..add(mime.codeUnits)
      ..addByte(0x00) // mime terminator
      ..addByte(0x03) // picture type: front cover
      ..addByte(0x00) // empty description
      ..add(imageBytes);
    final bodyBytes = body.takeBytes();

    final frame = Uint8List(10 + bodyBytes.length);
    frame.setRange(0, 4, 'APIC'.codeUnits);
    if (version == 4) {
      _writeSyncsafe(frame, 4, bodyBytes.length);
    } else {
      frame[4] = (bodyBytes.length >> 24) & 0xFF;
      frame[5] = (bodyBytes.length >> 16) & 0xFF;
      frame[6] = (bodyBytes.length >> 8) & 0xFF;
      frame[7] = bodyBytes.length & 0xFF;
    }
    // frame flags (2 bytes) stay zero
    frame.setRange(10, frame.length, bodyBytes);
    return frame;
  }

  static String? _mimeFor(Uint8List b) {
    if (b[0] == 0xFF && b[1] == 0xD8) return 'image/jpeg';
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return 'image/png';
    }
    return null;
  }

  static int _readSyncsafe(List<int> b, int o) =>
      ((b[o] & 0x7F) << 21) |
      ((b[o + 1] & 0x7F) << 14) |
      ((b[o + 2] & 0x7F) << 7) |
      (b[o + 3] & 0x7F);

  static int _readUint32(List<int> b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  static void _writeSyncsafe(Uint8List b, int o, int v) {
    b[o] = (v >> 21) & 0x7F;
    b[o + 1] = (v >> 14) & 0x7F;
    b[o + 2] = (v >> 7) & 0x7F;
    b[o + 3] = v & 0x7F;
  }
}
