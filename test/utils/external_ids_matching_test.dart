import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/external_ids.dart';

void main() {
  group('ExternalIds.intersects', () {
    test('matches when any shared id form is equal', () {
      const trakt = ExternalIds(imdb: 'tt0133093', tmdb: 603);
      expect(trakt.intersects(const ExternalIds(tmdb: 603)), isTrue);
      expect(trakt.intersects(const ExternalIds(imdb: 'tt0133093', tvdb: 999)), isTrue);
    });

    test('never matches on absent or differing ids', () {
      const trakt = ExternalIds(imdb: 'tt0133093');
      expect(trakt.intersects(const ExternalIds(tmdb: 603)), isFalse);
      expect(trakt.intersects(const ExternalIds(imdb: 'tt9999999')), isFalse);
      expect(const ExternalIds().intersects(const ExternalIds()), isFalse);
    });
  });

}
