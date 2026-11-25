import '../mpv/mpv.dart';
import '../utils/language_codes.dart';
import 'ted_models.dart';

String tedLanguage(String? value) {
  final base = (value ?? '').trim().toLowerCase().split(RegExp('[-_]')).first;
  return LanguageCodes.getIso6391Code(base) ?? (RegExp(r'^[a-z]{2,3}$').hasMatch(base) && base != 'und' ? base : '');
}

String tedLanguageTitle(TedMediaIdentity media) =>
    media.kind == 'episode' ? 'series/${media.id.split(':').first}' : '${media.kind}/${media.id}';

class TedTrackLanguages {
  final String audio, subtitle;
  const TedTrackLanguages({this.audio = '', this.subtitle = ''});
  AudioTrack audioTrack(List<AudioTrack> tracks, String original, {String? selectedId}) {
    final selected = [AudioTrack.auto, ...tracks].where((track) => track.id == selectedId).firstOrNull;
    if (selected != null) return selected;
    for (final language in [audio, original, 'en'].map(tedLanguage).where((s) => s.isNotEmpty)) {
      final matches = tracks.where((t) => tedLanguage(t.language) == language).toList()
        ..sort(
          (a, b) => a.isDefault == b.isDefault
              ? 0
              : a.isDefault
              ? -1
              : 1,
        );
      if (matches.isNotEmpty) return matches.first;
    }
    return tracks.where((t) => t.isDefault).firstOrNull ?? tracks.firstOrNull ?? AudioTrack.auto;
  }

  SubtitleTrack subtitleTrack(List<SubtitleTrack> tracks, {String? selectedId}) {
    final selected = [
      SubtitleTrack.off,
      SubtitleTrack.auto,
      ...tracks,
    ].where((track) => track.id == selectedId).firstOrNull;
    if (selected != null) return selected;
    for (final language in [subtitle, 'en'].map(tedLanguage).where((s) => s.isNotEmpty)) {
      final matches = tracks.where((t) => tedLanguage(t.language) == language).toList()
        ..sort(
          (a, b) => a.isForced != b.isForced
              ? a.isForced
                    ? 1
                    : -1
              : a.isDefault == b.isDefault
              ? 0
              : a.isDefault
              ? -1
              : 1,
        );
      if (matches.isNotEmpty) return matches.first;
    }
    return tracks.where((t) => t.isDefault).firstOrNull ?? tracks.firstOrNull ?? SubtitleTrack.auto;
  }

  /// MPV numbers embedded tracks from one independently for each type. Use
  /// the same policy before opening and when the native inventory arrives.
  /// External subtitle containers can contain multiple tracks, so their IDs
  /// are deliberately resolved from MPV rather than predicted here.
  TrackSelection initialTracks(
    TedContainerTracks container,
    String original, {
    String? audioId,
    String? subtitleId,
    String? secondarySubtitleId,
    bool externalSubtitles = false,
  }) {
    final audio = [
      for (final (index, track) in container.audio.indexed)
        AudioTrack(
          id: '${index + 1}',
          language: track.language,
          codec: track.codec,
          isDefault: track.isDefault,
          isForced: track.isForced,
        ),
    ];
    final subtitles = [
      for (final (index, track) in container.subtitles.indexed)
        SubtitleTrack(
          id: '${index + 1}',
          language: track.language,
          codec: track.codec,
          isDefault: track.isDefault,
          isForced: track.isForced,
        ),
    ];
    return TrackSelection(
      audio: audioTrack(audio, original, selectedId: audioId),
      subtitle: externalSubtitles ? null : subtitleTrack(subtitles, selectedId: subtitleId),
      secondarySubtitle: externalSubtitles
          ? null
          : [SubtitleTrack.off, ...subtitles].where((track) => track.id == secondarySubtitleId).firstOrNull,
    );
  }
}
