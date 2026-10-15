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
  AudioTrack audioTrack(List<AudioTrack> tracks, String original) {
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

  SubtitleTrack subtitleTrack(List<SubtitleTrack> tracks) {
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
}
