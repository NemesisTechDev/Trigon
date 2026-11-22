import 'addon_models.dart';
import 'stream_rules.dart';

/// The one-line description of a link shown in the download list:
///
///   `1080p • Direct link • English • DDP 5.1 • BluRay H.265 10bit HDR MKV`
///
/// quality, link type (never the addon's name), the size (when the caller
/// gives one), audio language(s) and audio format, and the video type
/// (source, codec, bit depth, HDR, container). A part the link's text does
/// not reveal is simply left out.
///
/// Pure and synchronous (no UI, no network).
class StreamSummary {
  StreamSummary._();

  /// The summary line for [s].
  ///
  /// [size] is shown right after the link type, ready formatted (for example
  /// `≈ 38.4 GB`), so it stays visible when a long line is cut at the end.
  static String line(
    AddonStream s, {
    LinkContext ctx = LinkContext.none,
    String? size,
  }) {
    final text = '${s.name}\n${s.description}\n${s.fileName ?? ''}';
    final parts = <String>[
      s.qualityLabel.isEmpty ? 'Unknown quality' : s.qualityLabel,
      s.typeLabel,
    ];
    if (size != null && size.isNotEmpty) parts.add(size);
    final language = _language(s, ctx);
    if (language != null) parts.add(language);
    final audio = _audioFormat(text);
    if (audio != null) parts.add(audio);
    final video = _videoType(s, text);
    if (video != null) parts.add(video);
    return parts.join(' • ');
  }

  // ---- language ----

  static String? _language(AddonStream s, LinkContext ctx) {
    final found = StreamRules.audioLanguageLabels(s, ctx);
    final labels = found.labels;
    if (labels.length >= 2) return 'Multi audio: ${labels.join(', ')}';
    if (found.multi) {
      return labels.isEmpty ? 'Multi audio' : 'Multi audio: ${labels.first}';
    }
    return labels.isEmpty ? null : labels.first;
  }

  // ---- audio format ----

  static const String _pre = r'(?<![A-Za-z0-9])';
  // Letters may not follow (so "DDP5.1" still reads as DDP), digits may.
  static const String _post = r'(?![A-Za-z])';

  static RegExp _re(String body) =>
      RegExp('$_pre(?:$body)$_post', caseSensitive: false);

  static final RegExp _atmos = _re('Atmos');
  static final RegExp _truehd = _re('TrueHD');
  static final RegExp _dtsX = _re(r'DTS[ ._-]?X');
  static final RegExp _dtsHd = _re(r'DTS[ ._-]?HD(?:[ ._-]?MA)?');
  static final RegExp _ddp = _re(r'DDP|DD\+|E[ ._-]?AC[ ._-]?3');
  static final RegExp _dd = _re(r'DD|AC[ ._-]?3|Dolby[ ._-]?Digital');
  static final RegExp _dts = _re('DTS');
  static final RegExp _aac = _re('AAC');
  static final RegExp _flac = _re('FLAC');
  static final RegExp _opus = _re('Opus');
  static final RegExp _mp3 = _re('MP3');

  // 7.1 / 5.1 / 2.0 / 1.0, but not a file size such as "5.1 GB".
  static final RegExp _channels = RegExp(
    r'(?<![0-9])(?<![0-9]\.)([75][ .]1|2[ .]0|1[ .]0)(?![0-9])'
    r'(?!\s*(?:GB|MB|TB|GiB|MiB|TiB|fps))',
    caseSensitive: false,
  );

  static String? _audioFormat(String text) {
    String? codec;
    if (_truehd.hasMatch(text)) {
      codec = 'TrueHD';
    } else if (_dtsX.hasMatch(text)) {
      codec = 'DTS:X';
    } else if (_dtsHd.hasMatch(text)) {
      codec = 'DTS-HD';
    } else if (_ddp.hasMatch(text)) {
      codec = 'DDP';
    } else if (_dd.hasMatch(text)) {
      codec = 'DD';
    } else if (_dts.hasMatch(text)) {
      codec = 'DTS';
    } else if (_aac.hasMatch(text)) {
      codec = 'AAC';
    } else if (_flac.hasMatch(text)) {
      codec = 'FLAC';
    } else if (_opus.hasMatch(text)) {
      codec = 'Opus';
    } else if (_mp3.hasMatch(text)) {
      codec = 'MP3';
    }
    final atmos = _atmos.hasMatch(text);
    final channelMatch = _channels.firstMatch(text);
    final channels = channelMatch?.group(1)?.replaceAll(' ', '.');

    final name = codec == null
        ? (atmos ? 'Atmos' : null)
        : (atmos ? '$codec Atmos' : codec);
    if (name == null) {
      // Channels alone are only trusted when they are surround layouts.
      if (channels == '5.1' || channels == '7.1') return channels;
      return null;
    }
    return channels == null ? name : '$name $channels';
  }

  // ---- video type ----

  static final RegExp _bluray = _re(r'Blu[ ._-]?Ray|BDRip|BRRip|BD[ ._-]?Remux');
  static final RegExp _remux = _re('Remux');
  static final RegExp _webDl = _re(r'WEB[ ._-]?DL');
  static final RegExp _webRip = _re(r'WEB[ ._-]?Rip');
  static final RegExp _hdRip = _re('HDRip');
  static final RegExp _dvdRip = _re(r'DVD[ ._-]?Rip');
  static final RegExp _hdtv = _re('HDTV');

  static final RegExp _h265 = _re(r'H[ ._-]?265');
  static final RegExp _h264 = _re(r'H[ ._-]?264');
  static final RegExp _x265 = _re('x265');
  static final RegExp _x264 = _re('x264');
  static final RegExp _hevc = _re('HEVC');
  static final RegExp _av1 = _re('AV1');
  static final RegExp _avc = _re('AVC');

  static final RegExp _tenBit = _re(r'10[ ._-]?bit');
  static final RegExp _dolbyVision = _re(r'Dolby[ ._-]?Vision|DoVi');
  // "DV" is only trusted in capitals (it is also an ordinary pair of letters).
  static final RegExp _dv = RegExp(r'(?<![A-Za-z0-9])DV(?![A-Za-z0-9])');
  static final RegExp _hdr10Plus = _re(r'HDR10\+|HDR10Plus');
  static final RegExp _hdr10 = _re('HDR10');
  static final RegExp _hdr = _re('HDR');
  static final RegExp _mkv = _re('MKV');
  static final RegExp _mp4 = _re('MP4');

  static String? _videoType(AddonStream s, String text) {
    final parts = <String>[];

    if (_bluray.hasMatch(text)) {
      parts.add(_remux.hasMatch(text) ? 'BluRay Remux' : 'BluRay');
    } else if (_remux.hasMatch(text)) {
      parts.add('Remux');
    } else if (_webDl.hasMatch(text)) {
      parts.add('WEB-DL');
    } else if (_webRip.hasMatch(text)) {
      parts.add('WEBRip');
    } else if (_hdRip.hasMatch(text)) {
      parts.add('HDRip');
    } else if (_dvdRip.hasMatch(text)) {
      parts.add('DVDRip');
    } else if (_hdtv.hasMatch(text)) {
      parts.add('HDTV');
    }

    // The codec as the release spells it.
    if (_h265.hasMatch(text)) {
      parts.add('H.265');
    } else if (_h264.hasMatch(text)) {
      parts.add('H.264');
    } else if (_x265.hasMatch(text)) {
      parts.add('x265');
    } else if (_x264.hasMatch(text)) {
      parts.add('x264');
    } else if (_hevc.hasMatch(text)) {
      parts.add('HEVC');
    } else if (_av1.hasMatch(text)) {
      parts.add('AV1');
    } else if (_avc.hasMatch(text)) {
      parts.add('AVC');
    }

    if (_tenBit.hasMatch(text)) parts.add('10bit');
    if (_dolbyVision.hasMatch(text) || _dv.hasMatch(text)) {
      parts.add('Dolby Vision');
    }
    if (_hdr10Plus.hasMatch(text)) {
      parts.add('HDR10+');
    } else if (_hdr10.hasMatch(text)) {
      parts.add('HDR10');
    } else if (_hdr.hasMatch(text)) {
      parts.add('HDR');
    }

    final path =
        s.isTorrent ? '' : (Uri.tryParse(s.url)?.path ?? '').toLowerCase();
    if (_mkv.hasMatch(text) || path.endsWith('.mkv')) {
      parts.add('MKV');
    } else if (_mp4.hasMatch(text) || path.endsWith('.mp4')) {
      parts.add('MP4');
    }

    return parts.isEmpty ? null : parts.join(' ');
  }
}
