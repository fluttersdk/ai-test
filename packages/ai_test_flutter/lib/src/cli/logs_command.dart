import 'dart:io' as io;

import 'package:args/command_runner.dart';

import 'state_file.dart';

/// `ai_test_flutter logs` — tails captured stdout from the running
/// `flutter run` process.
///
/// Reads `~/.ai-test/flutter-dev.log` (written by `start` when stdout capture
/// is enabled). When the log file is absent prints a guidance line; the V3
/// `start` command currently scrapes stdout for the URI then detaches without
/// keeping a logfile, so absence is the common case for now.
///
/// `--follow` (`-f`) tails new lines as they arrive (production behaviour);
/// without `--follow` the command prints the file once and exits.
class LogsCommand extends Command<void> {
  /// Constructs the command.
  LogsCommand({StringSink? stdout}) : _out = stdout ?? io.stdout {
    argParser.addFlag(
      'follow',
      abbr: 'f',
      defaultsTo: false,
      help: 'Tail new lines as they arrive instead of printing once.',
    );
  }

  final StringSink _out;

  @override
  final String name = 'logs';

  @override
  final String description =
      'Print or tail captured stdout from the running `flutter run` process.';

  @override
  Future<void> run() async {
    final String logPath = '${io.Directory(StateFile.path).parent.path}'
        '${io.Platform.pathSeparator}flutter-dev.log';
    final io.File logFile = io.File(logPath);

    if (!logFile.existsSync()) {
      _out.writeln(
        'No log file at $logPath — `start` may not have captured stdout.\n'
        'Use `tail` against the flutter-bound terminal directly.',
      );
      return;
    }

    final bool follow = argResults!['follow'] as bool;
    if (!follow) {
      _out.writeln(logFile.readAsStringSync());
      return;
    }

    // Follow mode: print existing content then poll the file for appended
    // bytes every 250ms. Cancellable by SIGINT (handled by the shell).
    int offset = 0;
    while (true) {
      final int length = logFile.lengthSync();
      if (length > offset) {
        final io.RandomAccessFile reader = logFile.openSync();
        reader.setPositionSync(offset);
        final List<int> bytes = reader.readSync(length - offset);
        reader.closeSync();
        _out.write(String.fromCharCodes(bytes));
        offset = length;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
}
