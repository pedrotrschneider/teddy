import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'ted_client.dart';
import 'ted_profile_avatar.dart';
import 'ted_user_watch.dart';

class TedUserAvatarScope extends InheritedWidget {
  final TedClient client;
  const TedUserAvatarScope({super.key, required this.client, required super.child});
  static TedClient? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TedUserAvatarScope>()?.client;
  @override
  bool updateShouldNotify(TedUserAvatarScope oldWidget) => client != oldWidget.client;
}

class TedUserAvatar extends StatelessWidget {
  final TedUserWatch watch;
  final double diameter;
  const TedUserAvatar({super.key, required this.watch, required this.diameter});
  @override
  Widget build(BuildContext context) {
    final client = TedUserAvatarScope.of(context);
    if (client == null || watch.avatarVersion.isEmpty) return TedProfileAvatar(name: watch.name, diameter: diameter);
    return FutureBuilder<Uint8List?>(
      key: ValueKey(
        '${identityHashCode(client)}/${client.auth.server}/${client.auth.userId}/${watch.accountId}/${watch.avatarVersion}',
      ),
      future: client.userPicture(watch),
      builder: (_, snapshot) => TedProfileAvatar(name: watch.name, image: snapshot.data, diameter: diameter),
    );
  }
}
