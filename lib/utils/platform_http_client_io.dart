import 'dart:io' show HttpClient, Platform;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:win_http/win_http.dart';

import 'app_logger.dart';
import 'happy_eyeballs.dart';
import 'managed_http_client.dart';
import 'media_server_timeouts.dart';

final Set<String> _loggedPlatformClients = <String>{};

void _logPlatformClient(String platform, String client) {
  if (!_loggedPlatformClients.add(client)) return;
  appLogger.i('Platform HTTP client', error: {'platform': platform, 'client': client});
}

ManagedHttpClient _createIoClient(String debugLabel, Duration connectTimeout) {
  final httpClient = HttpClient()
    ..connectionTimeout = connectTimeout
    ..maxConnectionsPerHost = 12
    ..idleTimeout = const Duration(seconds: 90)
    ..connectionFactory = happyEyeballsConnectionFactory;
  return ManagedHttpClient(IOClient(httpClient), debugLabel: debugLabel, forceCloseOnDrainTimeout: true);
}

/// Every platform except Windows runs on the tuned dart:io client.
///
/// Windows keeps WinHTTP for the system proxy and the Schannel trust store.
/// Its `WINHTTP_OPTION_IPV6_FAST_FALLBACK` (#1128) is what
/// [happyEyeballsConnectionFactory] now supplies everywhere else.
///
/// Cronet and NSURLSession used to serve Android and Apple here. Both were
/// measured slower than this client on the request shapes Plezy actually
/// issues — Cronet by ~10x on LAN body throughput — so neither survived; see
/// issue #2140.
///
/// Both transports bound only the connect, to [connectTimeout]. Waiting on
/// the server is left to the caller's deadlines, as dart:io already does:
/// WinHTTP's own 30 s per-read default would otherwise cut a slow server's
/// answer short and surface it as a connection error, which endpoint failover
/// reads as a dead endpoint (#2581).
http.Client createPlatformClient({Duration connectTimeout = MediaServerTimeouts.connect}) {
  if (Platform.isWindows) {
    try {
      final client = WinHttpClient.fromConfiguration(
        // A zero receive timeout is WinHTTP's "wait indefinitely".
        WinHttpClientConfiguration(connectTimeout: connectTimeout, receiveTimeout: Duration.zero),
      );
      _logPlatformClient('windows', 'WinHttpClient');
      return ManagedHttpClient(client, debugLabel: 'WinHttpClient');
    } catch (e, st) {
      appLogger.w('WinHttpClient init failed, falling back to IOClient', error: e, stackTrace: st);
      _logPlatformClient('windows', 'IOClient (fallback)');
      return _createIoClient('IOClient (fallback)', connectTimeout);
    }
  }
  _logPlatformClient(Platform.operatingSystem, 'IOClient');
  return _createIoClient('IOClient', connectTimeout);
}
