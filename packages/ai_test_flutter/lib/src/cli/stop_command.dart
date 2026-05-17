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

/// Signature for the test-injectable liveness probe.
///
/// Production code uses `ps -p <pid>` (exit code 0 = alive); tests stub the
/// probe so the SIGKILL escalation branch is reachable without spawning real
/// processes.
typedef LivenessProbe = bool Function(int pid);

/// `ai_test_flutter stop` — reads `~/.ai-test/state.json`, terminates the
/// recorded `flutter run` process AND its Chrome browser child (D6), removes
/// the temporary Chrome user-data-dir, and removes the state file.
///
/// The command is idempotent: if no state file exists it exits silently
/// without error. This allows calling `stop` defensively before `start` to
/// clean up any orphaned process from a previous session.
///
/// ### D6 cascade
/// When `state.chromePid` is present the command sends SIGTERM to Chrome first,
/// then to the Flutter dev server. After `postSigtermDelay` it probes liveness;
/// any PID still alive escalates to SIGKILL. This mirrors Flutter tools' own
/// 3-phase shutdown ([Chromium.close] in flutter_tools/web/chrome.dart).
///
/// When `state.tmpProfileDir` is present the command then deletes the directory
/// recursively. macOS and Linux create one fresh `flutter_tools_chrome_device.*`
/// dir per `flutter run -d chrome`; failing to clean it up leaks GB of disk
/// over time. Failure to delete is non-fatal (best-effort cleanup).
///
/// ### Windows caveat
/// On Windows the kill is performed via `Process.killPid` which sends a
/// best-effort SIGTERM (internally mapped to TerminateProcess). The dual-PID
/// cascade and tmp-dir cleanup still run, but Windows tree-kill semantics
/// differ — operators may need `taskkill /T /F /PID <flutterPid>` for stuck
/// child processes.
class StopCommand extends Command<void> {
  /// Constructs the command.
  ///
  /// [killPid] defaults to [Process.killPid]; [isAlive] defaults to a `ps -p`
  /// probe; [postSigtermDelay] defaults to 2 seconds (the SIGTERM grace
  /// window). Tests inject fakes for all three to bypass real processes and
  /// real wall-clock waits.
  ///
  /// [stderr] is optional and defaults to [io.stderr]; warnings about missing
  /// `chromePid` or failed tmp cleanup write here so the operator sees that
  /// the GC is degraded for the session without polluting the structured
  /// stdout messages.
  StopCommand({
    KillFunction? killPid,
    LivenessProbe? isAlive,
    Duration? postSigtermDelay,
    StringSink? stderr,
  })  : _killPid = killPid ?? Process.killPid,
        _isAlive = isAlive ?? _psProbe,
        _postSigtermDelay = postSigtermDelay ?? const Duration(seconds: 2),
        _stderr = stderr ?? ioStderr;

  final KillFunction _killPid;
  final LivenessProbe _isAlive;
  final Duration _postSigtermDelay;
  final StringSink _stderr;

  @override
  final String name = 'stop';

  @override
  final String description =
      'Terminate the running `flutter run` process and remove state.json.\n'
      'Idempotent — safe to call even when no process is recorded.\n'
      '\n'
      'D6 cascade: kills the recorded Chrome PID (if captured) then the '
      'Flutter PID via SIGTERM, escalates to SIGKILL after 2s for any PID '
      'still alive, and deletes the Chrome temporary user-data-dir.\n'
      '\n'
      'Windows caveat: termination is best-effort (TerminateProcess) and '
      'is not graceful. The web port may remain in use briefly after stop '
      'returns; use `taskkill /T /F /PID <flutterPid>` for stuck children.';

  @override
  Future<void> run() async {
    // 1. Read state; nothing to do when absent.
    final Map<String, dynamic>? state = await StateFile.read();
    if (state == null) {
      stdout.writeln(
          'ai_test_flutter stop: no state.json found — nothing to stop.');
      return;
    }

    // 2. Extract PIDs. chromePid is nullable (legacy state, capture failure,
    //    or a non-chrome device target where no Chrome process exists).
    final int flutterPid = state['pid'] as int;
    final int? chromePid = state['chromePid'] as int?;
    final String? tmpProfileDir = state['tmpProfileDir'] as String?;
    final String device = (state['device'] as String?) ?? 'chrome';
    final bool isChromeTarget = device == 'chrome';

    if (chromePid == null && isChromeTarget) {
      _stderr.writeln(
        'ai_test_flutter stop: no chromePid in state — GC degraded for this '
        'session. Chrome browser process may persist as orphan; clean up '
        'manually with `pgrep -fl flutter_tools_chrome_device`.',
      );
    }

    // 3. SIGTERM cascade. Chrome first so it doesn't outlive its parent and
    //    leak as an orphan; flutter second.
    final List<int> targets = <int>[
      if (chromePid != null) chromePid,
      flutterPid,
    ];
    for (final int pid in targets) {
      _killPid(pid, ProcessSignal.sigterm);
    }
    stdout.writeln(
        'ai_test_flutter stop: sent SIGTERM to pids=${targets.join(', ')}.');

    // 4. Grace window, then SIGKILL escalation for any survivor.
    await Future<void>.delayed(_postSigtermDelay);
    for (final int pid in targets) {
      if (_isAlive(pid)) {
        _killPid(pid, ProcessSignal.sigkill);
        stdout.writeln('ai_test_flutter stop: escalated to SIGKILL pid=$pid.');
      }
    }

    // 5. Remove the temporary Chrome user-data-dir (best-effort).
    if (tmpProfileDir != null) {
      try {
        final Directory dir = Directory(tmpProfileDir);
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
          stdout.writeln(
              'ai_test_flutter stop: removed tmpProfileDir=$tmpProfileDir.');
        }
      } catch (e) {
        _stderr.writeln(
          'ai_test_flutter stop: failed to remove tmpProfileDir='
          '$tmpProfileDir: $e (continuing).',
        );
      }
    }

    // 6. Remove the state file so subsequent commands do not reference a dead
    //    process.
    await StateFile.delete();
    stdout.writeln('ai_test_flutter stop: state.json removed.');
  }

  /// Default liveness probe: `ps -p <pid>` exits 0 when the PID is alive.
  /// Synchronous because the stop command awaits a grace window separately.
  static bool _psProbe(int pid) {
    try {
      final ProcessResult result =
          Process.runSync('ps', <String>['-p', '$pid']);
      return result.exitCode == 0;
    } catch (_) {
      // If `ps` is unavailable, assume the process is gone — safer than
      // looping SIGKILL forever.
      return false;
    }
  }
}

/// Indirection so the constructor's default for [StopCommand._stderr] can name
/// `stderr` without shadowing the Dart core symbol inside the class body.
final StringSink ioStderr = stderr;
