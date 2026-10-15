/// One lyric line. [startMs] is the offset from track start, `null` when the
/// source is unsynced plain text.
class LyricLine {
  final String text;
  final int? startMs;

  const LyricLine({required this.text, this.startMs});
}

class Lyrics {
  final bool synced;
  final List<LyricLine> lines;

  const Lyrics({required this.synced, required this.lines});

  bool get isEmpty => lines.isEmpty;
}
