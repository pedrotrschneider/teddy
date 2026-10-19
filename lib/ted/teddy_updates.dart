import 'dart:convert';
import 'package:http/http.dart' as http;

/// Only our published numeric stable/rc releases participate in update checks.
class TeddyVersion implements Comparable<TeddyVersion> {
  final int major, minor, patch;
  final int? rc;
  const TeddyVersion(this.major, this.minor, this.patch, this.rc);
  static TeddyVersion? parse(String value) {
    final match = RegExp(
      r'^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-rc([1-9][0-9]*))?$',
    ).firstMatch(value);
    if (match == null) return null;
    return TeddyVersion(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
      match[4] == null ? null : int.parse(match[4]!),
    );
  }

  @override
  int compareTo(TeddyVersion other) {
    for (final pair in [(major, other.major), (minor, other.minor), (patch, other.patch)]) {
      final result = pair.$1.compareTo(pair.$2);
      if (result != 0) return result;
    }
    if (rc == other.rc) return 0;
    if (rc == null) return 1;
    if (other.rc == null) return -1;
    return rc!.compareTo(other.rc!);
  }

  @override
  String toString() => '$major.$minor.$patch${rc == null ? '' : '-rc$rc'}';
}

class TeddyUpdate {
  final TeddyVersion version;
  final Uri releaseUrl;
  final Map<String, Uri> assets;
  const TeddyUpdate(this.version, this.releaseUrl, this.assets);
}

class TeddyUpdates {
  static const repository = 'pedrotrschneider/teddy';
  static TeddyUpdate? select(List<dynamic> releases, String current, bool candidates) {
    final installed = TeddyVersion.parse(current);
    if (installed == null) return null; // Unversioned development builds are manual.
    TeddyUpdate? best;
    for (final item in releases) {
      if (item is! Map || item['draft'] != false || item['tag_name'] is! String) continue;
      final version = TeddyVersion.parse(item['tag_name']);
      if (version == null ||
          version.major != installed.major ||
          (installed.major == 0 && version.minor != installed.minor) ||
          (!candidates && (version.rc != null || item['prerelease'] != false)) ||
          version.compareTo(installed) <= 0 ||
          (best != null && version.compareTo(best.version) <= 0)) {
        continue;
      }
      final assets = <String, Uri>{};
      if (item['assets'] is! List) continue;
      for (final asset in item['assets']) {
        if (asset is! Map ||
            asset['name'] is! String ||
            asset['browser_download_url'] is! String ||
            asset['state'] != 'uploaded') {
          continue;
        }
        final uri = Uri.tryParse(asset['browser_download_url']);
        if (uri != null &&
            uri.scheme == 'https' &&
            uri.host == 'github.com' &&
            uri.path.startsWith('/$repository/releases/download/v$version/')) {
          assets[asset['name']] = uri;
        }
      }
      if (assets.isEmpty) continue;
      best = TeddyUpdate(version, Uri.https('github.com', '/$repository/releases/tag/v$version'), assets);
    }
    return best;
  }

  static Future<TeddyUpdate?> check(String current, bool candidates) async {
    final client = http.Client();
    try {
      final releases = <dynamic>[];
      // Include stable releases even if many newer candidates were published.
      for (final path in ['/repos/$repository/releases?per_page=100', '/repos/$repository/releases/latest']) {
        final response = await client
            .get(Uri.parse('https://api.github.com$path'), headers: {'Accept': 'application/vnd.github+json'})
            .timeout(const Duration(seconds: 10));
        if (response.statusCode == 404 && path.endsWith('/latest')) continue;
        if (response.statusCode != 200) throw StateError('Update service unavailable');
        final body = jsonDecode(response.body);
        if (body is List) {
          releases.addAll(body);
        } else if (body is Map) {
          releases.add(body);
        } else {
          throw const FormatException('Invalid release response');
        }
      }
      return select(releases, current, candidates);
    } finally {
      client.close();
    }
  }
}
