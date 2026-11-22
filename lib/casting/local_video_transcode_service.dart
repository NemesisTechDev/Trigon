import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';

import 'local_cast_format.dart';

/// On-device counterpart to `MediaService.getVideoCastTranscodeUrl` for a
/// **local** file (an "On This Device" song/video, or something opened
/// via Android's Open With/Play With — see [MediaItem.isLocal]): there is
/// no Jellyfin server to remux a file that only ever existed on this
/// phone, so this does the exact same job — repackage an MKV into an
/// MPEG-TS container Cast's Default Media Receiver can actually open —
/// with FFmpeg running locally instead of on a server.
///
/// **Android-only, for now.** This app builds Android exclusively at the
/// moment (see pubspec.yaml's comment history), so this hasn't been
/// exercised on iOS/desktop at all — the `Platform.isAndroid` guard below
/// is a deliberate scope limit, not a technical ceiling: the underlying
/// `ffmpeg_kit_flutter_new_min` package also ships iOS/macOS/Windows
/// builds, so widening this later should mostly be a matter of removing
/// the guard and testing, not new native work.
///
/// **Stream-copy only, deliberately not a full re-encode.** This mirrors
/// `GoogleCastTransport._needsContainerTranscodeForCast`'s scope exactly:
/// that check only ever routes a file here when the *codecs* are already
/// Cast-compatible (h264/aac) and only the *container* is wrong, so a
/// `-c copy` remux — repackaging existing bytes into new container
/// framing, no decode/encode at all — is all that's ever asked of this.
/// The difference from the server-side fix is that there's no equivalent
/// check here yet for a local file's actual codecs (no local prober
/// exists in this codebase — Jellyfin items get real codec metadata from
/// the server, a local file currently doesn't), so this finds out the
/// same way `ffmpeg -c copy` always finds out: it fails fast with a
/// non-zero return code if the source codec genuinely isn't
/// Cast-compatible, and that failure is surfaced as a clear
/// [LocalCastUnsupportedException] rather than silently producing a
/// broken file. A real fix for *that* file (HEVC video, DTS/TrueHD audio,
/// etc.) would mean a full on-device re-encode, which is a meaningfully
/// bigger feature — CPU-bound, not a fast passthrough, and needs
/// progressive/segmented output rather than "wait for the whole file"
/// the way this does, so a 2-hour movie doesn't have to fully encode
/// before Cast's load watchdog gives up waiting. Deliberately left as a
/// known gap rather than attempted here.
class LocalVideoTranscodeService {
  LocalVideoTranscodeService._();
  static final LocalVideoTranscodeService instance =
      LocalVideoTranscodeService._();

  /// Generous but bounded — this is a stream copy, not a re-encode, so
  /// even a large file should finish in well under a minute on any
  /// device this app targets; if it hasn't by 90s, something's
  /// genuinely wrong (a corrupt file, an ffmpeg crash) rather than just
  /// slow, and it's better to surface that than hang the cast attempt
  /// indefinitely.
  static const Duration _timeout = Duration(seconds: 90);

  /// The audio-track switch remuxes the WHOLE file (the receiver needs a
  /// complete, seekable stream to resume at the current position), so a
  /// multi-GB movie legitimately takes longer than [_timeout]'s cover-
  /// the-first-audio-track remux — killing it at 90s just threw away
  /// work that was still progressing.
  static const Duration _audioSwitchTimeout = Duration(minutes: 5);

  /// Remuxes the MKV at [inputPath] (already resolved to a real,
  /// directly-openable filesystem path — see
  /// `LocalCastServer._resolveReadableSource`, which runs before this is
  /// called, so this never has to deal with a `content://` URI itself)
  /// into a new `.ts` file under the app's temp directory. Returns the
  /// output path on success; throws [LocalCastUnsupportedException] on
  /// any failure (unsupported platform, ffmpeg error, or timeout) with a
  /// message safe to show the person directly.
  ///
  /// The caller ([LocalCastServer.registerMedia]) owns deleting the
  /// output file again once the cast session ends — this only creates
  /// it.
  Future<String> remuxToMpegTs({
    required String inputPath,
    required String title,
  }) async {
    if (!Platform.isAndroid) {
      throw LocalCastUnsupportedException(
        '"$title" can\'t be cast — on-device conversion for local MKV '
        'files is currently only supported on Android.',
      );
    }

    final tempDir = await getTemporaryDirectory();
    final outputPath = '${tempDir.path}/nemesis_local_cast_'
        '${DateTime.now().millisecondsSinceEpoch}.ts';

    // `-map 0:v:0 -map 0:a:0?` rather than a bare `-map 0`: picks the
    // first video track and, if present, the first audio track
    // explicitly, so a file with an embedded subtitle or attachment
    // stream (common in MKV) doesn't drag something MPEG-TS can't carry
    // along into the remux and fail the whole thing. The trailing `?` on
    // the audio map makes it optional, for the rare silent/video-only
    // file. `-c copy` is the entire point: no decode, no encode, just
    // repackaging existing bytes into new container framing.
    final command = '-y -i "$inputPath" '
        '-map 0:v:0 -map 0:a:0? -c copy '
        '-f mpegts "$outputPath"';

    try {
      final session = await FFmpegKit.execute(command).timeout(_timeout);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        return outputPath;
      }

      if (ReturnCode.isCancel(returnCode)) {
        throw LocalCastUnsupportedException(
          '"$title" took too long to prepare for casting and was '
          'cancelled.',
        );
      }

      // A non-zero, non-cancel return code here is almost always
      // `-c copy` refusing a codec MPEG-TS can't carry (HEVC video on an
      // older ffmpeg build, DTS/TrueHD audio, etc.) — see this class's
      // doc comment on why that's surfaced as "can't be cast" rather
      // than silently retried as a full re-encode.
      final logs = await session.getAllLogsAsString();
      debugPrint(
        'LocalVideoTranscodeService: remux failed for "$title" '
        '(command: $command): $logs',
      );
      throw LocalCastUnsupportedException(
        '"$title" can\'t be cast — converting it for the TV failed. '
        'This usually means its video or audio codec isn\'t supported '
        'by Cast, not just the file format.',
      );
    } on TimeoutException {
      unawaited(FFmpegKit.cancel());
      throw LocalCastUnsupportedException(
        '"$title" took too long to prepare for casting and was '
        'cancelled.',
      );
    }
  }

  /// Lists the AUDIO streams of the file at [inputPath], in container order
  /// (position N here == `0:a:N` in ffmpeg terms, the exact index
  /// [remuxToMpegTsWithAudio] takes). Used when a local video is sent
  /// STRAIGHT to an already-connected TV: local mpv never opens that file,
  /// so nothing else knows which audio tracks it has, and without a list
  /// the Audio button could never be enabled (see PlaybackCoordinator
  /// ._seedLocalCastAudio).
  ///
  /// Runs `ffmpeg -i <file>` with no output: ffmpeg prints the input's
  /// stream table to its log and then exits non-zero ("at least one output
  /// file must be specified") — the non-zero code is expected and ignored,
  /// only the log is read. Needs no extra package beyond the ffmpeg build
  /// this service already uses, and only reads the container headers, so it
  /// is quick even for a multi-GB file.
  ///
  /// Never throws: any failure (unsupported platform, ffmpeg error,
  /// timeout) returns an empty list, which just leaves the Audio button
  /// disabled exactly as before.
  Future<List<LocalAudioStreamInfo>> probeAudioStreams({
    required String inputPath,
  }) async {
    if (!Platform.isAndroid) return const [];

    try {
      final session = await FFmpegKit.execute(
        '-hide_banner -nostdin -i "$inputPath"',
      ).timeout(_probeTimeout);
      final logs = await session.getAllLogsAsString() ?? '';
      return parseAudioStreams(logs);
    } on TimeoutException {
      // Deliberately NO `FFmpegKit.cancel()` here (unlike the remux
      // methods): a bare cancel() stops EVERY running ffmpeg session, and
      // this probe runs alongside the MKV remux that starts the cast. A
      // header-only `-i` read ends on its own; the result is just dropped.
      return const [];
    } catch (e) {
      debugPrint('LocalVideoTranscodeService: audio probe failed: $e');
      return const [];
    }
  }

  static const Duration _probeTimeout = Duration(seconds: 20);

  static final RegExp _streamLine = RegExp(
    r'Stream #\d+:(\d+)(?:\[[^\]]*\])?(?:\(([^)]*)\))?[^:]*: (Audio|Video|Subtitle|Data|Attachment):\s*([^\s,(]+)',
  );
  static final RegExp _titleLine = RegExp(r'^\s*title\s*:\s*(.+?)\s*$');

  /// Parses the stream table ffmpeg logs for an input. Only the FIRST
  /// "Input #0" block is read, and only Audio streams are returned.
  @visibleForTesting
  static List<LocalAudioStreamInfo> parseAudioStreams(String log) {
    final out = <LocalAudioStreamInfo>[];

    var inInput = false;
    var seenInput = false;
    // Which stream the most recent "Stream #" line belonged to, so a
    // following "title : ..." metadata line can be attached to it.
    var currentIsAudio = false;

    for (final raw in log.split(RegExp(r'\r?\n'))) {
      if (raw.startsWith('Input #')) {
        if (seenInput) break; // second input block — nothing more to read
        seenInput = true;
        inInput = true;
        continue;
      }
      if (!inInput) continue;

      // The input block ends where ffmpeg starts talking about outputs /
      // errors ("Output #0", "At least one output file ...").
      if (raw.startsWith('Output #') || raw.startsWith('At least one')) {
        break;
      }

      final stream = _streamLine.firstMatch(raw);
      if (stream != null) {
        currentIsAudio = stream.group(3) == 'Audio';
        if (currentIsAudio) {
          final lang = (stream.group(2) ?? '').trim();
          out.add(
            LocalAudioStreamInfo(
              language: lang == 'und' ? '' : lang,
              codec: stream.group(4) ?? '',
              title: '',
              isDefault: raw.contains('(default)'),
            ),
          );
        }
        continue;
      }

      if (currentIsAudio && out.isNotEmpty) {
        final title = _titleLine.firstMatch(raw);
        if (title != null && out.last.title.isEmpty) {
          final last = out.removeLast();
          out.add(
            LocalAudioStreamInfo(
              language: last.language,
              codec: last.codec,
              title: title.group(1)!,
              isDefault: last.isDefault,
            ),
          );
        }
      }
    }

    return out;
  }

  /// AUDIO-TRACK SWITCH FOR LOCAL CASTING: the Default Media Receiver can't
  /// switch between audio streams inside a progressive MP4/MPEG-TS file —
  /// it always plays whichever one it picked at load. So (the same way
  /// VLC's own Cast feature does it) switching means producing a NEW
  /// stream that only contains the chosen audio track and reloading the
  /// TV with it at the current position.
  ///
  /// [audioIndex] is the 0-based position of the wanted track among the
  /// file's AUDIO streams (`0:a:N` in ffmpeg terms) — the same order mpv
  /// lists them in, which is what PlayerManager's Open With track list
  /// (`AudioTrack.index`) is built from.
  ///
  /// Stream-copies first (instant, lossless). If MPEG-TS can't carry that
  /// audio codec as-is (DTS/TrueHD/FLAC are common in MKVs), retries with
  /// just the AUDIO re-encoded to AAC stereo — cheap next to a video
  /// re-encode, and the video is still copied untouched. Throws
  /// [LocalCastUnsupportedException] only if both attempts fail.
  Future<String> remuxToMpegTsWithAudio({
    required String inputPath,
    required String title,
    required int audioIndex,
  }) async {
    if (!Platform.isAndroid) {
      throw LocalCastUnsupportedException(
        'Switching audio tracks while casting "$title" is currently only '
        'supported on Android.',
      );
    }

    final tempDir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final outputPath =
        '${tempDir.path}/nemesis_local_cast_a${audioIndex}_$stamp.ts';

    final attempts = <String>[
      '-y -i "$inputPath" -map 0:v:0 -map 0:a:$audioIndex -c copy '
          '-f mpegts "$outputPath"',
      '-y -i "$inputPath" -map 0:v:0 -map 0:a:$audioIndex -c:v copy '
          '-c:a aac -b:a 192k -ac 2 -f mpegts "$outputPath"',
    ];

    try {
      for (final command in attempts) {
        debugPrint('LocalVideoTranscodeService: audio-track remux: $command');
        final session =
            await FFmpegKit.execute(command).timeout(_audioSwitchTimeout);
        final returnCode = await session.getReturnCode();

        if (ReturnCode.isSuccess(returnCode)) {
          // A "successful" run that left nothing behind must not be
          // handed to the TV as if it were a stream.
          final out = File(outputPath);
          if (await out.exists() && await out.length() > 0) {
            return outputPath;
          }
          debugPrint(
            'LocalVideoTranscodeService: audio-track remux reported '
            'success but "$outputPath" is missing/empty.',
          );
          continue;
        }

        if (ReturnCode.isCancel(returnCode)) break;

        final logs = await session.getAllLogsAsString();
        debugPrint(
          'LocalVideoTranscodeService: audio-track remux attempt failed '
          'for "$title" (command: $command): $logs',
        );
      }
    } on TimeoutException {
      unawaited(FFmpegKit.cancel());
    }

    // Never leave a partial/corrupt file behind for a later attempt to
    // pick up by name.
    try {
      final partial = File(outputPath);
      if (await partial.exists()) await partial.delete();
    } catch (_) {}

    throw LocalCastUnsupportedException(
      'Couldn\'t switch "$title" to that audio track for the TV — it may '
      'use a format Cast can\'t play.',
    );
  }
}

/// One audio stream of a local video file, as read by
/// [LocalVideoTranscodeService.probeAudioStreams].
class LocalAudioStreamInfo {
  const LocalAudioStreamInfo({
    required this.language,
    required this.codec,
    required this.title,
    required this.isDefault,
  });

  /// ISO code from the container ("eng"), empty when untagged/"und".
  final String language;

  /// ffmpeg codec name ("aac", "ac3", "eac3", "dts", ...).
  final String codec;

  /// The container's own track title ("Commentary"), empty when none.
  final String title;

  final bool isDefault;
}
