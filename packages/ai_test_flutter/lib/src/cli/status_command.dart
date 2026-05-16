import 'dart:convert';
import 'dart:io' as io;

import 'package:args/command_runner.dart';

import 'state_file.dart';

/// Signature for the test-injectable liveness-check hook.
///
/// Returns `true` when the process with [pid] is alive. Production code uses
/// a platform-specific implementation; tests inject a fake that does not
/// interrogate real PIDs.
typedef LivenessChecker = bool Function(int pid);

/// `ai_test_flutter status` — reads `~/.ai-test/state.json` and prints a JSON
/// object describing the current state of the recorded `flutter run` instance.
///
/// Output shape when running:
/// ```json
/// {
///   "running": true,
///   "pid": 12345,
///   "alive": true,
///   "vmServiceUri": "ws://127.0.0.1:8181/<token>/ws",
///   "webPort": 3100,
///   "startedAt": "2026-05-16T10:00:00.000Z"
/// }
/// ```
///
/// Output shape when no state file is present:
/// ```json
/// { "running": false }
/// ```
class StatusCommand extends Command<void> {
  /// Constructs the command.
  ///
  /// [stdout] defaults to [io.stdout]; tests inject a [StringBuffer] wrapper.
  /// [isAlive] defaults to the platform liveness check; tests inject a fake.
  StatusCommand({
    StringSink? stdout,
    LivenessChecker? isAlive,
  })  : _out = stdout ?? io.stdout,
        _isAlive = isAlive ?? _platformLiveness;

  final StringSink _out;
  final LivenessChecker _isAlive;

  @override
  final String name = 'status';

  @override
  final String description =
      'Print JSON status of the recorded `flutter run` process.\n'
      '\n'
      'Exits 0 in all cases — inspect the "alive" field to determine whether '
      'the process is still running.';

  @override
  Future<void> run() async {
    // 1. Absent state means no process is recorded.
    final Map<String, dynamic>? state = await StateFile.read();
    if (state == null) {
      _out.writeln(const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'running': false,
      }));
      return;
    }

    // 2. Run the liveness check against the recorded PID.
    final int pid = state['pid'] as int;
    final bool alive = _isAlive(pid);

    // 3. Emit the status object.
    final Map<String, dynamic> output = <String, dynamic>{
      'running': true,
      'pid': pid,
      'alive': alive,
      'vmServiceUri': state['vmServiceUri'],
      'webPort': state['webPort'],
      'startedAt': state['startedAt'],
    };
    _out.writeln(const JsonEncoder.withIndent('  ').convert(output));
  }

  /// Platform liveness check used in production.
  ///
  /// macOS/Linux: `kill -0 <pid>` exits 0 when the process is alive.
  /// Windows: `tasklist /FI "PID eq <pid>"` output parsed for the PID.
  static bool _platformLiveness(int pid) {
    if (io.Platform.isWindows) {
      final io.ProcessResult result = io.Process.runSync(
        'tasklist',
        <String>['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV'],
      );
      final String output = result.stdout.toString();
      return output.contains('"$pid"');
    }
    // POSIX: exit code 0 means the process exists and we have permission to
    // signal it. Any non-zero exit means the process is gone.
    final io.ProcessResult result = io.Process.runSync(
      'kill',
      <String>['-0', '$pid'],
    );
    return result.exitCode == 0;
  }
}
