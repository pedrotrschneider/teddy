/// TED's shared contract is major.minor during alpha and major from 1.0.
class TedCompatibility {
  final int major;
  final int? minor;
  const TedCompatibility._(this.major, this.minor);

  static TedCompatibility? parse(String? value) {
    if (value == null || value.length > 24) return null;
    final match = RegExp(r'^(?:0\.(0|[1-9][0-9]*)|([1-9][0-9]*))$').firstMatch(value);
    if (match == null) return null;
    final major = match[2] == null ? 0 : int.tryParse(match[2]!);
    final minor = match[1] == null ? null : int.tryParse(match[1]!);
    if (major == null || (major == 0 && minor == null)) return null;
    return TedCompatibility._(major, minor);
  }

  bool accepts(int releaseMajor, int releaseMinor) => releaseMajor == major && (major != 0 || releaseMinor == minor);

  String get releaseFamily => major == 0 ? '0.$minor.x' : '$major.x';

  @override
  String toString() => major == 0 ? '0.$minor' : '$major';

  @override
  bool operator ==(Object other) => other is TedCompatibility && major == other.major && minor == other.minor;

  @override
  int get hashCode => Object.hash(major, minor);
}

class TedCompatibilityIssue {
  final Uri server;
  final TedCompatibility? requiredVersion;
  const TedCompatibilityIssue(this.server, this.requiredVersion);

  @override
  bool operator ==(Object other) =>
      other is TedCompatibilityIssue && server == other.server && requiredVersion == other.requiredVersion;

  @override
  int get hashCode => Object.hash(server, requiredVersion);
}
