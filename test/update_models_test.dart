// Run with: dart test test/update_models_test.dart  (or flutter test)
import 'package:flutter_test/flutter_test.dart';
import 'package:trigon/services/update/update_models.dart';

ReleaseInfo rel(String v, {String body = '', bool force = false}) => ReleaseInfo(
      version: AppVersion.tryParse(v)!,
      tag: 'v$v',
      notes: body,
      apkUrl: 'https://x/$v.apk',
      apkName: '$v.apk',
      apkSize: 1,
      forced: force,
    );

void main() {
  final cur = AppVersion.tryParse('1.0.0')!;

  test('parses versions', () {
    expect(AppVersion.tryParse('v1.2.3+4').toString(), '1.2.3');
    expect(AppVersion.tryParse('2.1').toString(), '2.1.0');
    expect(AppVersion.tryParse('1.2.3-beta').toString(), '1.2.3');
    expect(AppVersion.tryParse('nope'), isNull);
    expect(AppVersion.tryParse('1.10.0')! > AppVersion.tryParse('1.9.0')!, isTrue);
  });

  test('3 releases behind is mandatory, 2 is not', () {
    final two = evaluateUpdate(current: cur, releases: [rel('1.1.0'), rel('1.2.0')])!;
    expect(two.majorUpdatesBehind, 2);
    expect(two.mandatory, isFalse);
    final three = evaluateUpdate(current: cur, releases: [rel('1.1.0'), rel('1.2.0'), rel('1.3.0')])!;
    expect(three.mandatory, isTrue);
    expect(three.latest.version.toString(), '1.3.0');
  });

  test('patch releases count too', () {
    final i = evaluateUpdate(current: cur, releases: [rel('1.0.1'), rel('1.0.2')])!;
    expect(i.majorUpdatesBehind, 2);
    expect(i.mandatory, isFalse);
    final j = evaluateUpdate(current: cur, releases: [rel('1.0.1'), rel('1.0.2'), rel('1.0.3')])!;
    expect(j.mandatory, isTrue);
  });

  test('up to date / newer than latest', () {
    expect(evaluateUpdate(current: cur, releases: [rel('1.0.0'), rel('0.9.0')]), isNull);
    expect(evaluateUpdate(current: cur, releases: []), isNull);
  });

  test('force marker makes it mandatory', () {
    final i = evaluateUpdate(current: cur, releases: [rel('1.0.1', force: true)])!;
    expect(i.mandatory, isTrue);
  });

  test('github parsing', () {
    final r = ReleaseInfo.fromGithub({
      'tag_name': 'v1.4.0',
      'draft': false,
      'prerelease': false,
      'body': '## New Features\r\n- **home**: fix [link](http://a)\n[force-update]',
      'assets': [
        {'name': 'a.zip', 'browser_download_url': 'u0', 'size': 1},
        {
          'name': 'trigon.apk',
          'browser_download_url': 'https://u',
          'size': 95000000,
          'state': 'uploaded',
          'digest': 'sha256:${'a' * 64}'
        },
      ],
    })!;
    expect(r.apkName, 'trigon.apk');
    expect(r.forced, isTrue);
    expect(r.sha256, 'a' * 64);
    expect(r.notes, 'New Features\n• home: fix link');
    expect(ReleaseInfo.fromGithub({'tag_name': 'v2.0.0', 'prerelease': true, 'assets': []}), isNull);
    expect(ReleaseInfo.fromGithub({'tag_name': 'v2.0.0', 'assets': []}), isNull);
  });

  test('cache round trip', () {
    final i = evaluateUpdate(current: cur, releases: [rel('1.1.0'), rel('1.2.0'), rel('1.3.0')])!;
    final back = UpdateInfo.fromJsonString(i.toJsonString())!;
    expect(back.mandatory, isTrue);
    expect(back.latest.version, i.latest.version);
  });
}
