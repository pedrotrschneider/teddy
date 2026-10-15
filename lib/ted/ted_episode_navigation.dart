import 'ted_client.dart';

class TedEpisodeTargets {
  final TedTitle? previous, next;
  const TedEpisodeTargets({this.previous, this.next});
}

enum TedPlayerAction { back, next, previous, completed }

class TedPlayerExit {
  final TedPlayerAction action;
  final TedTitle? target;
  const TedPlayerExit(this.action, {this.target});
}
