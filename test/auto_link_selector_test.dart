import 'package:flutter_test/flutter_test.dart';
import 'package:trigon/addons/addon_models.dart';
import 'package:trigon/catalog/auto_link_selector.dart';
import 'package:trigon/services/app_settings.dart';

AddonStream _torrent(String id, int height, int? seeders, {int? peers}) =>
    AddonStream(
      addonId: 'a',
      addonName: 'A',
      name: id,
      description: '',
      url: 'magnet:?xt=urn:btih:$id',
      height: height,
      infoHash: '0123456789abcdef0123456789abcdef01234567',
      jsonSeeders: seeders,
      jsonPeers: peers,
    );

AddonStream _direct(String id, int height) => AddonStream(
      addonId: 'a',
      addonName: 'A',
      name: id,
      description: '',
      url: 'https://example.com/$id.mp4',
      height: height,
    );

void main() {
  test('Default picks the 720p torrent with the most seeders', () {
    final c = AutoLinkSelector.select([
      _torrent('1080', 1080, 900),
      _torrent('720-low', 720, 5),
      _torrent('720-top', 720, 80),
      _torrent('480', 480, 500),
    ], PlaybackQualityMode.standard)!;
    expect(c.stream.name, '720-top');
    expect(c.overridden, false);
  });

  test('peers break a seeder tie', () {
    final c = AutoLinkSelector.select([
      _torrent('a', 720, 10, peers: 2),
      _torrent('b', 720, 10, peers: 9),
    ], PlaybackQualityMode.standard)!;
    expect(c.stream.name, 'b');
  });

  test('Max Quality picks 1080p', () {
    final c = AutoLinkSelector.select([
      _torrent('720', 720, 900),
      _torrent('1080', 1080, 3),
    ], PlaybackQualityMode.maxQuality)!;
    expect(c.stream.name, '1080');
    expect(c.overridden, false);
  });

  test('Data Saver prefers 360p, then 480p without an override', () {
    final both = AutoLinkSelector.select([
      _torrent('480', 480, 900),
      _torrent('360', 360, 2),
      _torrent('720', 720, 900),
    ], PlaybackQualityMode.dataSaver)!;
    expect(both.stream.name, '360');
    expect(both.overridden, false);

    final only480 = AutoLinkSelector.select([
      _torrent('480', 480, 4),
      _torrent('720', 720, 900),
    ], PlaybackQualityMode.dataSaver)!;
    expect(only480.stream.name, '480');
    expect(only480.overridden, false);
  });

  test('Data Saver with no usable 360p/480p falls back to 720p, overridden', () {
    final missing = AutoLinkSelector.select([
      _torrent('720', 720, 50),
      _torrent('1080', 1080, 500),
    ], PlaybackQualityMode.dataSaver)!;
    expect(missing.stream.name, '720');
    expect(missing.overridden, true);

    final zero = AutoLinkSelector.select([
      _torrent('360', 360, 0),
      _torrent('480', 480, 0),
      _torrent('720', 720, 50),
    ], PlaybackQualityMode.dataSaver)!;
    expect(zero.stream.name, '720');
    expect(zero.overridden, true);
  });

  test('a torrent with 0 seeders is never picked', () {
    final c = AutoLinkSelector.select([
      _torrent('dead', 720, 0, peers: 40),
      _torrent('alive', 720, 1),
    ], PlaybackQualityMode.standard)!;
    expect(c.stream.name, 'alive');
    expect(
      AutoLinkSelector.select(
          [_torrent('dead', 720, 0)], PlaybackQualityMode.standard),
      isNull,
    );
  });

  test('a direct link outranks a torrent of the same quality', () {
    final c = AutoLinkSelector.select([
      _torrent('t', 720, 999),
      _direct('d', 720),
    ], PlaybackQualityMode.standard)!;
    expect(c.stream.name, 'd');
  });

  test('selectAlways still plays something when every link has 0 seeders', () {
    final c = AutoLinkSelector.selectAlways([
      _torrent('720-dead', 720, 0),
      _torrent('480-dead', 480, 0),
    ], PlaybackQualityMode.standard)!;
    expect(c.stream.name, '720-dead');
    expect(c.overridden, true);
  });

  test('selectAlways prefers a suitable link and gives null only when empty',
      () {
    final c = AutoLinkSelector.selectAlways([
      _torrent('dead', 720, 0),
      _torrent('alive', 480, 3),
    ], PlaybackQualityMode.standard)!;
    expect(c.stream.name, 'alive');
    expect(AutoLinkSelector.selectAlways([], PlaybackQualityMode.standard),
        isNull);
  });

  test('empty list gives nothing', () {
    expect(AutoLinkSelector.select([], PlaybackQualityMode.standard), isNull);
  });
}
