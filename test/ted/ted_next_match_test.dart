import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/next_episode_matching_strategy.dart';
import 'package:plezy/ted/ted_models.dart';
import 'package:plezy/ted/ted_next_match.dart';
import 'package:plezy/ted/ted_source_models.dart';

const strategy = NextEpisodeMatchingStrategy.bestGuess;
const episode = TedMediaIdentity('episode', 'tt1234567:1:1');
TedSourceChoice release(String id, String file, {String addon = 'addon', String binge = '', String pack = ''}) =>
    TedSourceChoice(
      id,
      'Addon',
      'Release',
      '',
      fileName: file,
      addonId: addon,
      bingeKey: binge,
      packKey: pack,
      rdDirectPlay: true,
    );
TedSourcePage page(List<TedSourceChoice> choices) => TedSourcePage(false, false, choices, [], null);
TedPlaybackSession session({String binge = ''}) =>
    TedPlaybackSession('session', episode, '', 100000, 0, source: 'addon', addonId: 'addon', bingeKey: binge);
void main() {
  test('strategy order favors unique binge then pack and never crosses add-ons', () {
    final origin = release('current', 'Series.S01E01.1080p.x265.AAC-GROUP', pack: 'pack');
    final named = release('named', 'Series.S01E02.1080p.x265.AAC-GROUP');
    final packed = release('packed', 'Another filename', pack: 'pack');
    final grouped = release('grouped', 'Different filename', binge: 'group');
    expect(
      matchNextRelease(session(binge: 'group'), page([named, packed, grouped]), strategy, origin: origin)?.id,
      'grouped',
    );
    expect(matchNextRelease(session(), page([named, packed]), strategy, origin: origin)?.id, 'packed');
    expect(
      matchNextRelease(session(), page([release('other', named.fileName, addon: 'other')]), strategy, origin: origin),
      isNull,
    );
    expect(matchNextRelease(session(), page([named]), NextEpisodeMatchingStrategy.bingeGroup, origin: origin), isNull);
    expect(matchNextRelease(session(binge: 'group'), page([grouped]), NextEpisodeMatchingStrategy.manual), isNull);
  });
  test('release normalization handles episode formats while preserving cut and release distinctions', () {
    final origin = release('current', 'Series (2024).S01E01.1080p.x265.AAC-GROUP.mkv');
    for (final marker in ['S02E03', '2x03', 'Season 2 Episode 3', 'S02_E03']) {
      final next = release('next', 'Series (2024).$marker.1080p.x265.AAC-GROUP.mkv');
      expect(normalizedEpisodeRelease(next), normalizedEpisodeRelease(origin), reason: marker);
      expect(matchNextRelease(session(), page([next]), strategy, origin: origin)?.id, 'next');
    }
    expect(normalizedEpisodeRelease(release('double', 'Series.S01E02E03.1080p.x265.AAC-GROUP.mkv')), isNull);
    expect(normalizedEpisodeRelease(release('year', 'Series.2024.1080p.x265.AAC-GROUP.mkv')), isNull);
    expect(
      normalizedEpisodeRelease(release('cut', 'Series (2024).S01E02.Extended.1080p.x265.AAC-GROUP.mkv')),
      isNot(normalizedEpisodeRelease(origin)),
    );
  });
  test('ambiguous stronger signals do not fall through to a guessed release', () {
    final origin = release('current', 'Series.S01E01.1080p.x265.AAC-GROUP');
    final good = release('first', 'Series.S01E02.1080p.x265.AAC-GROUP', binge: 'group');
    final another = release('second', 'Different.720p.H264.DTS', binge: 'group');
    expect(matchNextRelease(session(binge: 'group'), page([good, another]), strategy, origin: origin), isNull);
    expect(
      matchNextRelease(session(), page([good, release('second', good.fileName)]), strategy, origin: origin),
      isNull,
    );
  });
  test('HDR and audio plus markers stay distinct and bitrate cannot break a technical tie', () {
    final origin = release('current', 'Series.S01E01.1080p.x265.DD+.5.1.HDR10+ 8 Mbps');
    final next = release('next', 'Series.S01E02.1080p.x265.DD+.5.1.HDR10 8 Mbps');
    expect(normalizedEpisodeRelease(origin), isNot(normalizedEpisodeRelease(next)));
    expect(releaseSignals(origin)['range'], 'hdr10+');
    expect(releaseSignals(origin)['audio'], 'eac3');
    expect(declaredReleaseBitrate(origin), 8000000);
    final a = release('a', 'Different A 1080p.x265.DDP5.1.HDR10+ 8000 kbit/s');
    final b = release('b', 'Different B 1080p.x265.DDP5.1.HDR10+ 12 Mb/s');
    expect(matchNextRelease(session(), page([a, b]), strategy, origin: origin), isNull);
    expect(matchNextRelease(session(), page([next]), strategy, origin: origin), isNull);
  });
  test('technical guesses require resolution video and audio and refuse ties or known conflicts', () {
    final origin = release('current', 'Series.S01E01.1080p.HEVC.EAC3.5.1.HDR10.English');
    final good = release('good', 'A different release.1080p.x265.DDP.5.1.HDR.English');
    expect(matchNextRelease(session(), page([good]), strategy, origin: origin)?.id, 'good');
    expect(matchNextRelease(session(), page([good, release('tie', good.fileName)]), strategy, origin: origin), isNull);
    expect(
      matchNextRelease(
        session(),
        page([release('wrong', 'Other.1080p.x265.AAC.5.1.HDR.English')]),
        strategy,
        origin: origin,
      ),
      isNull,
    );
    expect(matchNextRelease(session(), page([release('generic', '1080p')]), strategy, origin: origin), isNull);
  });
}
