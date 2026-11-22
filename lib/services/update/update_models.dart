import 'dart:convert';

import 'update_config.dart';

/// A `major.minor.patch` version. Parses `1.2.3`, `v1.2.3`, `1.2`, `1.2.3+4`
/// and `1.2.3-beta` (anything after the three numbers is ignored).
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static final RegExp _pattern =
      RegExp(r'^[^0-9]*(\d+)(?:\.(\d+))?(?:\.(\d+))?');

  static AppVersion? tryParse(String? raw) {
    if (raw == null) return null;
    final m = _pattern.firstMatch(raw.trim());
    if (m == null) return null;
    final major = int.tryParse(m.group(1) ?? '');
    if (major == null) return null;
    return AppVersion(
      major,
      int.tryParse(m.group(2) ?? '') ?? 0,
      int.tryParse(m.group(3) ?? '') ?? 0,
    );
  }

  /// Same `major.minor` line (so only the patch number can differ).
  bool sameLine(AppVersion other) =>
      major == other.major && minor == other.minor;

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;
  bool operator <(AppVersion other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// How many releases the installed [current] version is behind: the number of
/// distinct [published] versions that are newer than it, of any kind (patch,
/// minor or major).
///
///   current 1.0.0, published 1.0.1, 1.1.0, 1.1.1 -> 3
///   current 5.3.1, published 5.4.0                -> 1
int majorUpdatesBehind(AppVersion current, Iterable<AppVersion> published) {
  final newer = <String>{};
  for (final v in published) {
    if (v > current) newer.add(v.toString());
  }
  return newer.length;
}

/// One published release that has an installable APK.
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.tag,
    required this.notes,
    required this.apkUrl,
    required this.apkName,
    required this.apkSize,
    this.sha256,
    this.forced = false,
  });

  final AppVersion version;
  final String tag;

  /// Release description, already cleaned up for plain-text display.
  final String notes;
  final String apkUrl;
  final String apkName;

  /// Bytes; 0 when GitHub did not say.
  final int apkSize;

  /// Lower-case hex SHA-256 of the APK when GitHub published one, else null.
  final String? sha256;

  /// The release description carries the `[force-update]` marker.
  final bool forced;

  Map<String, dynamic> toJson() => {
        'version': version.toString(),
        'tag': tag,
        'notes': notes,
        'apkUrl': apkUrl,
        'apkName': apkName,
        'apkSize': apkSize,
        'sha256': sha256,
        'forced': forced,
      };

  static ReleaseInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final version = AppVersion.tryParse(raw['version']?.toString());
    final url = raw['apkUrl']?.toString() ?? '';
    if (version == null || url.isEmpty) return null;
    return ReleaseInfo(
      version: version,
      tag: raw['tag']?.toString() ?? 'v$version',
      notes: raw['notes']?.toString() ?? '',
      apkUrl: url,
      apkName: raw['apkName']?.toString() ?? 'update.apk',
      apkSize: (raw['apkSize'] as num?)?.toInt() ?? 0,
      sha256: raw['sha256']?.toString(),
      forced: raw['forced'] == true,
    );
  }

  /// Reads one entry of GitHub's `GET /repos/{repo}/releases` answer. Returns
  /// null for drafts, pre-releases, tags that are not a version and releases
  /// without an uploaded APK - none of those can be offered as an update.
  static ReleaseInfo? fromGithub(Object? raw) {
    if (raw is! Map) return null;
    if (raw['draft'] == true || raw['prerelease'] == true) return null;

    final tag = raw['tag_name']?.toString() ?? '';
    final version = AppVersion.tryParse(tag);
    if (version == null) return null;

    final assets = raw['assets'];
    if (assets is! List) return null;
    final apk = _pickApk(assets);
    if (apk == null) return null;

    final body = raw['body']?.toString() ?? '';

    String? sha;
    final digest = apk['digest']?.toString() ?? '';
    if (digest.toLowerCase().startsWith('sha256:')) {
      final hex = digest.substring(7).trim().toLowerCase();
      if (RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) sha = hex;
    }

    return ReleaseInfo(
      version: version,
      tag: tag,
      notes: cleanReleaseNotes(body),
      apkUrl: apk['browser_download_url'].toString(),
      apkName: apk['name'].toString(),
      apkSize: (apk['size'] as num?)?.toInt() ?? 0,
      sha256: sha,
      forced: UpdateConfig.forceMarker.hasMatch(body),
    );
  }

  /// Picks the APK to install. One universal APK is the expected setup; if a
  /// release carries several, prefer "universal", then one with no ABI in its
  /// name, then arm64.
  static Map<String, dynamic>? _pickApk(List<dynamic> assets) {
    final apks = <Map<String, dynamic>>[];
    for (final a in assets) {
      if (a is! Map) continue;
      final name = a['name']?.toString().toLowerCase() ?? '';
      final url = a['browser_download_url']?.toString() ?? '';
      final state = a['state']?.toString() ?? 'uploaded';
      if (name.endsWith('.apk') && url.isNotEmpty && state == 'uploaded') {
        apks.add(Map<String, dynamic>.from(a));
      }
    }
    if (apks.isEmpty) return null;
    if (apks.length == 1) return apks.first;

    int score(Map<String, dynamic> a) {
      final n = a['name'].toString().toLowerCase();
      if (n.contains('universal')) return 3;
      if (!RegExp(r'arm|x86|abi').hasMatch(n)) return 2;
      if (n.contains('arm64')) return 1;
      return 0;
    }

    apks.sort((a, b) => score(b).compareTo(score(a)));
    return apks.first;
  }
}

/// Turns a GitHub release description (markdown) into plain text for the
/// "What's New" box: no headings marks, bold, links or HTML comments; list
/// items become bullets; the `[force-update]` marker is dropped.
String cleanReleaseNotes(String raw) {
  var s = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  s = s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  s = s.replaceAll(UpdateConfig.forceMarker, '');
  // [text](url) -> text, ![alt](url) -> nothing
  s = s.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '');
  s = s.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m.group(1)!);
  s = s.replaceAll(RegExp(r'<[^>\n]+>'), '');
  s = s.replaceAll('**', '').replaceAll('__', '').replaceAll('`', '');

  final lines = <String>[];
  for (final line in s.split('\n')) {
    var l = line.trimRight();
    l = l.replaceFirst(RegExp(r'^\s{0,3}#{1,6}\s*'), '');
    l = l.replaceFirstMapped(RegExp(r'^(\s*)[-*+]\s+'), (m) => '${m.group(1)}• ');
    l = l.replaceFirst(RegExp(r'^\s*(?:-{3,}|\*{3,}|_{3,})\s*$'), '');
    lines.add(l);
  }
  return lines.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// An update that is available for the installed version.
class UpdateInfo {
  const UpdateInfo({
    required this.current,
    required this.latest,
    required this.majorUpdatesBehind,
    required this.mandatory,
  });

  final AppVersion current;
  final ReleaseInfo latest;
  final int majorUpdatesBehind;

  /// The installed version may no longer be used until it is updated.
  final bool mandatory;

  String toJsonString() => jsonEncode({
        'current': current.toString(),
        'latest': latest.toJson(),
        'behind': majorUpdatesBehind,
        'mandatory': mandatory,
      });

  static UpdateInfo? fromJsonString(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final current = AppVersion.tryParse(m['current']?.toString());
      final latest = ReleaseInfo.fromJson(m['latest']);
      if (current == null || latest == null) return null;
      return UpdateInfo(
        current: current,
        latest: latest,
        majorUpdatesBehind: (m['behind'] as num?)?.toInt() ?? 0,
        mandatory: m['mandatory'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Decides, from every published [releases] entry, whether [current] has an
/// update, and whether that update is mandatory. Null = up to date.
UpdateInfo? evaluateUpdate({
  required AppVersion current,
  required List<ReleaseInfo> releases,
  int forceAfter = UpdateConfig.forceAfterMajorUpdates,
}) {
  final newer = releases.where((r) => r.version > current).toList();
  if (newer.isEmpty) return null;
  newer.sort((a, b) => b.version.compareTo(a.version));

  final behind = majorUpdatesBehind(current, newer.map((r) => r.version));
  final flagged = newer.any((r) => r.forced);
  return UpdateInfo(
    current: current,
    latest: newer.first,
    majorUpdatesBehind: behind,
    mandatory: behind >= forceAfter || flagged,
  );
}
