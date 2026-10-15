/// TVDB sometimes supplies an original-script name and an English name in
/// one role. Presentation prefers the English part without rewriting metadata.
String tedEnglishCharacterNames(Iterable<String> roles) {
  final originalScript = RegExp(r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]');
  final latin = RegExp(r'[A-Za-z\u00c0-\u024f\u1e00-\u1eff]');
  final names = <String>{};
  for (final role in roles) {
    for (var name in role.split('/')) {
      name = name.replaceAllMapped(RegExp(r'\([^)]*\)|（[^）]*）'), (match) {
        return originalScript.hasMatch(match[0]!) ? '' : match[0]!;
      }).trim();
      if (latin.hasMatch(name) && !originalScript.hasMatch(name)) names.add(name);
    }
  }
  return names.join(' / ');
}
