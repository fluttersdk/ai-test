@TestOn('vm')
library;

import 'dart:io';

import 'package:ai_test_flutter/src/cli/state_file.dart';
import 'package:ai_test_flutter/src/cli/stop_command.dart';
import 'package:args/command_runner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for [StopCommand] D6 enhancements (Layer 4 of Step 7 plan):
/// dual SIGTERM→SIGKILL cascade + tmp profile dir cleanup.
///
/// Builds on the pre-existing single-PID stop coverage in `cli_commands_test.dart`.
/// Focus here is only the D6 additions:
///
///   1. `state.chromePid != null` → SIGTERM to Chrome before flutter PID.
///   2. After SIGTERM, processes still alive (per injected liveness probe)
///      escalate to SIGKILL.
///   3. `state.tmpProfileDir != null` → directory recursively deleted on stop.
///   4. Legacy state (no chromePid, no tmpProfileDir) still works; only the
///      flutter PID is killed and no tmp cleanup attempted.
void main() {
  late Directory tempHome;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('ai_test_stop_d6_');
    StateFile.debugHomeOverride = tempHome.path;
  });

  tearDown(() {
    StateFile.debugHomeOverride = null;
    if (tempHome.existsSync()) {
      tempHome.deleteSync(recursive: true);
    }
  });

  /// Boots a [CommandRunner] containing [command] and runs it with [args].
  Future<void> runCmd(StopCommand command, List<String> args) {
    final CommandRunner<void> runner =
        CommandRunner<void>('ai_test_flutter', 'test')..addCommand(command);
    return runner.run(args);
  }

  group('StopCommand D6: dual-PID cascade', () {
    test('sends SIGTERM to chromePid before flutterPid when both present',
        () async {
      await StateFile.write(<String, dynamic>{
        'pid': 1000,
        'chromePid': 2000,
        'tmpProfileDir': null,
      });

      final List<(int, ProcessSignal)> killCalls = <(int, ProcessSignal)>[];
      final StopCommand cmd = StopCommand(
        killPid: (int pid, ProcessSignal signal) {
          killCalls.add((pid, signal));
          return true;
        },
        // Both processes "die cleanly" after SIGTERM — no SIGKILL needed.
        isAlive: (int pid) => false,
        postSigtermDelay: Duration.zero,
      );

      await runCmd(cmd, <String>['stop']);

      // Chrome SIGTERM precedes flutter SIGTERM (Chrome is the child; kill it
      // first so its parent doesn't try to keep it alive).
      expect(
          killCalls,
          equals(<(int, ProcessSignal)>[
            (2000, ProcessSignal.sigterm),
            (1000, ProcessSignal.sigterm),
          ]));
    });

    test('escalates to SIGKILL when processes survive SIGTERM', () async {
      await StateFile.write(<String, dynamic>{
        'pid': 1000,
        'chromePid': 2000,
        'tmpProfileDir': null,
      });

      final List<(int, ProcessSignal)> killCalls = <(int, ProcessSignal)>[];
      final StopCommand cmd = StopCommand(
        killPid: (int pid, ProcessSignal signal) {
          killCalls.add((pid, signal));
          return true;
        },
        // Both processes "stuck alive" after SIGTERM.
        isAlive: (int pid) => true,
        postSigtermDelay: Duration.zero,
      );

      await runCmd(cmd, <String>['stop']);

      expect(
          killCalls,
          equals(<(int, ProcessSignal)>[
            (2000, ProcessSignal.sigterm),
            (1000, ProcessSignal.sigterm),
            (2000, ProcessSignal.sigkill),
            (1000, ProcessSignal.sigkill),
          ]));
    });

    test('skips Chrome kill and warns when chromePid is absent (legacy state)',
        () async {
      // Legacy state — no chromePid, no tmpProfileDir.
      await StateFile.write(<String, dynamic>{'pid': 1000});

      final List<int> killedPids = <int>[];
      final StringBuffer warnings = StringBuffer();
      final StopCommand cmd = StopCommand(
        killPid: (int pid, ProcessSignal signal) {
          killedPids.add(pid);
          return true;
        },
        isAlive: (int pid) => false,
        postSigtermDelay: Duration.zero,
        stderr: warnings,
      );

      await runCmd(cmd, <String>['stop']);

      expect(killedPids, equals(<int>[1000]),
          reason: 'only flutter PID killed when chromePid missing');
      expect(warnings.toString(), contains('chromePid'),
          reason: 'operator must see that GC is degraded for this session');
    });
  });

  group('StopCommand D6: tmpProfileDir cleanup', () {
    test('deletes tmpProfileDir recursively when present', () async {
      // Create a real tmp dir with some content to verify recursive deletion.
      final Directory profileDir =
          Directory.systemTemp.createTempSync('flutter_tools_chrome_device.');
      File('${profileDir.path}/Default.html').writeAsStringSync('test');
      Directory('${profileDir.path}/Cache').createSync();
      expect(profileDir.existsSync(), isTrue);

      await StateFile.write(<String, dynamic>{
        'pid': 1000,
        'chromePid': 2000,
        'tmpProfileDir': profileDir.path,
      });

      final StopCommand cmd = StopCommand(
        killPid: (int pid, ProcessSignal signal) => true,
        isAlive: (int pid) => false,
        postSigtermDelay: Duration.zero,
      );

      await runCmd(cmd, <String>['stop']);

      expect(profileDir.existsSync(), isFalse,
          reason: 'tmpProfileDir must be removed recursively on stop');
    });

    test('survives missing tmpProfileDir (already deleted) without throwing',
        () async {
      // Path that does not exist.
      final String ghostPath =
          '${Directory.systemTemp.path}/flutter_tools_chrome_device.ghost';
      expect(Directory(ghostPath).existsSync(), isFalse);

      await StateFile.write(<String, dynamic>{
        'pid': 1000,
        'chromePid': 2000,
        'tmpProfileDir': ghostPath,
      });

      final StopCommand cmd = StopCommand(
        killPid: (int pid, ProcessSignal signal) => true,
        isAlive: (int pid) => false,
        postSigtermDelay: Duration.zero,
      );

      // Must not throw — cleanup is best-effort.
      await runCmd(cmd, <String>['stop']);
      expect(File(StateFile.path).existsSync(), isFalse,
          reason: 'state.json still removed even when tmp cleanup is a no-op');
    });

    test('skips tmp cleanup when tmpProfileDir is null', () async {
      await StateFile.write(<String, dynamic>{
        'pid': 1000,
        'chromePid': 2000,
        'tmpProfileDir': null,
      });

      final StopCommand cmd = StopCommand(
        killPid: (int pid, ProcessSignal signal) => true,
        isAlive: (int pid) => false,
        postSigtermDelay: Duration.zero,
      );

      // No throw, no real-fs operation needed.
      await runCmd(cmd, <String>['stop']);
      expect(File(StateFile.path).existsSync(), isFalse);
    });
  });
}
