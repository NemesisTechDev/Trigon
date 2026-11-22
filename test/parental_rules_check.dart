// Plain-Dart check of the Parental Controls rules engine.
// Run from the project root:  dart run test/parental_rules_check.dart
import '../lib/services/parental/parental_models.dart';

int fails = 0;
void check(String name, bool ok) {
  if (!ok) { fails++; print('FAIL: $name'); }
}

void main() {
  // --- rating scale
  check('US PG-13', RatingScale.levelOf('US', 'PG-13') == 2);
  check('US TV-MA', RatingScale.levelOf('US', ' tv-ma ') == 3);
  check('US NR null', RatingScale.levelOf('US', 'NR') == null);
  check('GB 15', RatingScale.levelOf('GB', '15') == 3);
  check('DE 6', RatingScale.levelOf('DE', '6') == 1);
  check('ceiling', RatingScale.tmdbMovieCeiling(2) == 'PG-13' && RatingScale.tmdbMovieCeiling(4) == null);

  // --- settings roundtrip + damage tolerance
  final s = ParentalSettings(
    enabled: true, maxLevel: 2,
    blockedGenres: {'horror', 'war'}, blockedWords: ['zombie', 'serial killer'],
    blockedTitles: [BlockedTitle('m603', 'The Matrix', year: 1999)],
    dailyLimitMinutes: [60, 60, 60, 60, 60, 120, 120],
    bedtimeEnabled: true, bedtimeDays: {1, 2, 3, 4, 7},
  );
  final back = ParentalSettings.decode(s.encode());
  check('roundtrip level', back.maxLevel == 2);
  check('roundtrip genres', back.blockedGenres.length == 2);
  check('roundtrip titles', back.blockedTitles.single.name == 'The Matrix');
  check('roundtrip limits', back.dailyLimitMinutes[5] == 120 && back.dailyLimitMinutes[0] == 60);
  check('garbage -> defaults', ParentalSettings.decode('{{{').enabled == false);
  check('garbage level clamps', ParentalSettings.decode('{"lvl": 99, "on": true}').maxLevel == 4);
  check('unknown genre dropped', ParentalSettings.decode('{"gen":["nope","horror"]}').blockedGenres.length == 1);

  // --- policy
  TitleFacts f(String id, {int? level, String? label, String name = 'X', String ov = '', Set<int> g = const {}, bool known = true}) =>
      TitleFacts(id: id, name: name, overview: ov, genreIds: g, level: level, ratingLabel: label, ratingKnown: known);

  check('blocked title', !ParentalPolicy.evaluate(s, f('m603', level: 0)).allowed);
  check('allowed PG', ParentalPolicy.evaluate(s, f('m1', level: 1, label: 'PG')).allowed);
  check('allowed PG-13 at teens', ParentalPolicy.evaluate(s, f('m1', level: 2, label: 'PG-13')).allowed);
  final r = ParentalPolicy.evaluate(s, f('m1', level: 3, label: 'R'));
  check('R blocked at teens', !r.allowed && r.reason == BlockReason.maturity);
  check('unrated blocked', ParentalPolicy.evaluate(s, f('m1')).reason == BlockReason.unrated);
  check('unknown fails closed', ParentalPolicy.evaluate(s, f('m1', known: false)).reason == BlockReason.unrated);
  check('unrated allowed when toggle off', ParentalPolicy.evaluate(s.copyWith(blockUnrated: false), f('m1')).allowed);
  check('genre by id', ParentalPolicy.evaluate(s, f('m1', level: 0, g: {27})).reason == BlockReason.genre);
  check('tv war id', ParentalPolicy.evaluate(s, f('s1', level: 0, g: {10768})).reason == BlockReason.genre);
  check('word match', ParentalPolicy.evaluate(s, f('m1', level: 0, ov: 'A ZOMBIE apocalypse')).reason == BlockReason.word);
  check('word phrase', ParentalPolicy.evaluate(s, f('m1', level: 0, ov: 'hunt for a Serial  killer')).allowed); // double space: no match
  check('word phrase ok', ParentalPolicy.evaluate(s, f('m1', level: 0, ov: 'hunt for a serial killer.')).reason == BlockReason.word);
  check('word is whole-word', ParentalPolicy.evaluate(s, f('m1', level: 0, ov: 'zombielike creatures')).allowed);
  check('no limit => rating ignored', ParentalPolicy.evaluate(const ParentalSettings(enabled: true), f('m1', level: 4)).allowed);
  check('no limit => unknown ok', ParentalPolicy.evaluate(const ParentalSettings(enabled: true), f('m1', known: false)).allowed);

  // --- screen time. 2026-11-16 is a Monday.
  final mon2200 = DateTime(2026, 11, 16, 22, 0);
  final tue0300 = DateTime(2026, 11, 17, 3, 0);
  final tue2200 = DateTime(2026, 11, 17, 22, 0);
  final fri2200 = DateTime(2026, 11, 20, 22, 0);
  final sat0300 = DateTime(2026, 11, 21, 3, 0);
  final sun0300 = DateTime(2026, 11, 22, 3, 0);
  final mon0300 = DateTime(2026, 11, 23, 3, 0);
  check('weekday math (Mon)', mon2200.weekday == 1 && sun0300.weekday == 7);
  // days {1,2,3,4,7} = Mon,Tue,Wed,Thu,Sun start a bedtime; Fri,Sat do not.
  check('Mon 22:00 bedtime', ScreenTime.isBedtime(s, mon2200));
  check('Tue 03:00 (Mon night)', ScreenTime.isBedtime(s, tue0300));
  check('Tue 22:00 bedtime', ScreenTime.isBedtime(s, tue2200));
  check('Fri 22:00 free', !ScreenTime.isBedtime(s, fri2200));
  check('Sat 03:00 (Fri night) free', !ScreenTime.isBedtime(s, sat0300));
  check('Sun 03:00 (Sat night) free', !ScreenTime.isBedtime(s, sun0300));
  check('Mon 03:00 (Sun night)', ScreenTime.isBedtime(s, mon0300));
  check('Mon noon free', !ScreenTime.isBedtime(s, DateTime(2026, 11, 16, 12)));
  check('edge: 21:00 sharp', ScreenTime.isBedtime(s, DateTime(2026, 11, 16, 21, 0)));
  check('edge: 06:59', ScreenTime.isBedtime(s, DateTime(2026, 11, 17, 6, 59)));
  check('edge: 07:00 free', !ScreenTime.isBedtime(s, DateTime(2026, 11, 17, 7, 0)));
  final ends = ScreenTime.bedtimeEnds(s, mon2200)!;
  check('bedtime ends next morning 07:00', ends == DateTime(2026, 11, 17, 7, 0));
  check('bedtime ends same morning', ScreenTime.bedtimeEnds(s, tue0300) == DateTime(2026, 11, 17, 7, 0));
  check('bedtime off', !ScreenTime.isBedtime(s.copyWith(bedtimeEnabled: false), mon2200));
  final day = s.copyWith(bedtimeStartMin: 13 * 60, bedtimeEndMin: 15 * 60);
  check('same-day window', ScreenTime.isBedtime(day, DateTime(2026, 11, 16, 14)) && !ScreenTime.isBedtime(day, DateTime(2026, 11, 16, 16)));
  check('until bedtime 5m', ScreenTime.untilBedtime(s, DateTime(2026, 11, 16, 20, 55)) == const Duration(minutes: 5));
  check('until bedtime far', ScreenTime.untilBedtime(s, DateTime(2026, 11, 16, 12)) == null);
  check('until bedtime on free night', ScreenTime.untilBedtime(s, DateTime(2026, 11, 20, 20, 55)) == null);
  check('limit Mon', ScreenTime.limitFor(s, mon2200) == 60);
  check('limit Sat', ScreenTime.limitFor(s, sat0300) == 120);
  check('secondsLeft', ScreenTime.secondsLeft(s, mon2200, usedSeconds: 3000) == 600);
  check('secondsLeft bonus', ScreenTime.secondsLeft(s, mon2200, usedSeconds: 3600, bonusMinutes: 15) == 900);
  check('secondsLeft over', ScreenTime.secondsLeft(s, mon2200, usedSeconds: 9999) == 0);
  check('secondsLeft none', ScreenTime.secondsLeft(const ParentalSettings(), mon2200, usedSeconds: 5) == null);
  check('fmt clock', ScreenTime.formatClock(0) == '12:00 AM' && ScreenTime.formatClock(13 * 60 + 5) == '1:05 PM');
  check('fmt minutes', ScreenTime.formatMinutes(90) == '1h 30m' && ScreenTime.formatMinutes(45) == '45 min' && ScreenTime.formatMinutes(120) == '2h');

  print(fails == 0 ? 'ALL PASSED' : '$fails FAILED');
}
