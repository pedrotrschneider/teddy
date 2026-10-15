import '../mpv/mpv.dart';
import '../media/media_source_info.dart';
import '../services/settings_service.dart';

/// Read embedded chapters from the file being played, online or offline.
/// Each node is read explicitly: mpv's string representation of a node list is
/// not JSON and must never be parsed as provider metadata.
Future<PlaybackExtras> tedPlaybackChapters(Player player, {int? durationMs}) async {
  final count = int.tryParse(await player.getProperty('chapter-list/count') ?? '') ?? 0;
  final chapters = <MediaChapter>[];
  if (count >= 0 && count <= 2000) {
    for (var i = 0; i < count; i++) {
      final seconds = double.tryParse(await player.getProperty('chapter-list/$i/time') ?? '');
      if (seconds == null || !seconds.isFinite || seconds < 0 || seconds > 604800) continue;
      chapters.add(
        MediaChapter(
          id: i,
          index: i,
          startTimeOffset: (seconds * 1000).round(),
          title: await player.getProperty('chapter-list/$i/title'),
        ),
      );
    }
  }
  chapters.sort((a, b) => a.startTimeOffset!.compareTo(b.startTimeOffset!));
  final runtime = player.state.duration.inMilliseconds;
  MediaChapter.backfillEndOffsets(chapters, runtimeMs: runtime > 0 ? runtime : durationMs);
  final settings = SettingsService.instance;
  return PlaybackExtras.withChapterFallback(
    chapters: chapters,
    markers: [],
    introPatternStr: settings.read(SettingsService.introPattern),
    creditsPatternStr: settings.read(SettingsService.creditsPattern),
  );
}
