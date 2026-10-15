import 'dart:io';
import 'package:path/path.dart' as p;
import '../utils/app_logger.dart';

/// A bounded, already-redacted diagnostic file, also usable without a server.
class TeddyLogs {
  static File? file;
  static Future<void> _writes = Future.value();
  static Future<void> initialize(Directory support) async {
    file = File(p.join(support.path, 'logs', 'teddy.log'));
    await file!.parent.create(recursive: true);
    MemoryLogOutput.onEntry = _append;
  }

  static void _append(LogEntry entry) {
    final raw =
        '${entry.timestamp.toUtc().toIso8601String()} ${entry.level.name.toUpperCase()} '
        '${entry.message}${entry.error == null ? '' : ' ${entry.error}'}\n';
    final line = raw.length <= 32768 ? raw : '${raw.substring(0, 32768)}…\n';
    _writes = _writes
        .then((_) async {
          final current = file!;
          if (await current.exists() && await current.length() > 2 * 1024 * 1024) {
            final previous = File('${current.path}.1');
            if (await previous.exists()) await previous.delete();
            await current.rename(previous.path);
          }
          await current.writeAsString(line, mode: FileMode.append, flush: true);
        })
        .catchError((Object _) {
          /* logging must not interrupt viewing */
        });
  }

  static Future<void> close() async {
    MemoryLogOutput.onEntry = null;
    await _writes;
  }

  static Future<String> reveal() async {
    if (file == null) throw const FileSystemException('Log location is unavailable');
    await _writes;
    if (!await file!.exists()) await file!.writeAsString('Teddy diagnostic log\n', flush: true);
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', file!.path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', file!.path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [file!.parent.path]);
    }
    return file!.path;
  }
}
