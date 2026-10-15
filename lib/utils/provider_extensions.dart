import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_library.dart';
import '../media/media_server_client.dart';
import '../i18n/strings.g.dart';

/// Optional client for shared presentation widgets. TED screens own their
/// authenticated requests and provide explicit artwork/playback callbacks.
extension ProviderExtensions on BuildContext {
  MediaServerClient? tryGetMediaClientWithFallback(ServerId? serverId) =>
      Provider.of<MediaServerClient?>(this, listen: false);

  MediaServerClient? tryGetMediaClientForServer(ServerId? serverId) =>
      serverId == null ? null : tryGetMediaClientWithFallback(serverId);

  MediaServerClient getMediaClientForServer(ServerId serverId) =>
      tryGetMediaClientForServer(serverId) ?? (throw Exception(t.errors.noClientAvailable));

  MediaServerClient getMediaClientWithFallback(ServerId? serverId) =>
      tryGetMediaClientWithFallback(serverId) ?? (throw Exception(t.errors.noClientAvailable));

  MediaServerClient getMediaClientForLibrary(MediaLibrary library) =>
      getMediaClientWithFallback(serverIdOrNull(library.serverId));

  MediaServerClient? getMediaClientForItemOrNull(MediaItem item, {bool isOffline = false}) =>
      isOffline ? null : tryGetMediaClientForServer(serverIdOrNull(item.serverId));

}
