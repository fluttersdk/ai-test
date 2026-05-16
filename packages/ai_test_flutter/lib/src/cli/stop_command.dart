import 'dart:io';

import 'package:args/command_runner.dart';

import 'state_file.dart';

/// Signature for the test-injectable process-kill hook.
///
/// Mirrors [Process.killPid] so production code passes [Process.killPid]
/// directly and tests pass a fake that records calls without touching real
/// PIDs. Dart does not support mocking top-level functions, so this typedef
/// is the seam.
typedef KillFunction = bool Function(int pid, ProcessSignal signal);

/// `ai_test_flutter stop` — reads `~/.ai-test/state.json`, terminates the
/// recorded `flutter run` process, and removes the state file.
///
/// The command is idempotent: if no state file exists it exits silently
/// without error. This allows calling `stop` defensively before `start` to
/// clean up any orphaned process from a previous session.
///
/// ### Windows caveat
/// On Windows the kill is performed via `Process.killPid` which sends a
/// best-effort SIGTERM (internally mapped to TerminateProcess). Flutter may
/// not shut down gracefully — the port may remain in use briefly after the
/// call returns. Wait a second before starting a new session on Windows.
class StopCommand extends Command<void> {
  /// Constructs the command.
  ///
  /// [killPid] defaults to [Process.killPid]; tests inject a fake. The seam
  /// prevents any real PID being killed during unit tests.
  StopCommand({KillFunction? killPid}) : _killPid = killPid ?? Process.killPid;

  final KillFunction _killPid;

  @override
  final String name = 'stop';

  @override
  final String description =
      'Terminate the running `flutter run` process and remove state.json.\n'
      'Idempotent — safe to call even when no process is recorded.\n'
      '\n'
      'Windows caveat: termination is best-effort (TerminateProcess) and '
      'is not graceful. The web port may remain in use briefly after stop '
      'returns.';

  @override
  Future<void> run() async {
    // 1. Read state; nothing to do when absent.
    final Map<String, dynamic>? state = await StateFile.read();
    if (state == null) {
      stdout.writeln(
          'ai_test_flutter stop: no state.json found — nothing to stop.');
      return;
    }

    // 2. Extract the PID and attempt termination.
    final int pid = state['pid'] as int;
    _killPid(pid, ProcessSignal.sigterm);
    stdout.writeln('ai_test_flutter stop: sent SIGTERM to pid=$pid.');

    // 3. Remove the state file so subsequent commands do not reference a dead
    //    process.
    await StateFile.delete();
    stdout.writeln('ai_test_flutter stop: state.json removed.');
  }
}
