import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:plezy/ted/ted_auth.dart';
import 'package:plezy/ted/ted_client.dart';
import 'package:plezy/ted/ted_models.dart';
import 'ted_auth_test.dart' show MemoryStore, pair, response;

void main() {
  test('server adjacency may reorder stable IDs but cannot cross series or duplicate targets', () async {
    final now = DateTime.utc(2026, 11, 20);
    Map<String, dynamic> title(String id) => {
      'media': {'kind': 'episode', 'id': id},
      'metadata': {},
      'watch_state': {'played': false, 'revision': 0, 'position_ms': 0},
      'local_available': false,
      'mapped_ready': false,
      'watchlist': false,
      'user_rating': null,
    };
    var next = title('tt1234567:1:1');
    Map<String, dynamic>? previous;
    final auth = TedAuth(
      store: MemoryStore(),
      now: () => now,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return response(pair(now));
        return response({'previous': previous, 'next': next});
      }),
    );
    addTearDown(auth.close);
    await auth.login('https://ted.example', 'fixture', '', 'test');
    final client = TedClient(auth);
    const current = TedMediaIdentity('episode', 'tt1234567:2:4');
    expect((await client.adjacentEpisodes(current)).next!.media.id, 'tt1234567:1:1');
    previous = next;
    await expectLater(client.adjacentEpisodes(current), throwsA(isA<TedFailure>()));
    previous = null;
    next = title('tt7654321:1:1');
    await expectLater(client.adjacentEpisodes(current), throwsA(isA<TedFailure>()));
  });
}
