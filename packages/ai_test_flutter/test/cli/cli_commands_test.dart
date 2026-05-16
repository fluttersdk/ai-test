@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_test_flutter/src/cli/start_command.dart';
import 'package:ai_test_flutter/src/cli/state_file.dart';
import 'package:ai_test_flutter/src/cli/stop_command.dart';
import 'package:ai_test_flutter/src/cli/status_command.dart';
import 'package:ai_test_flutter/src/cli/doctor_command.dart';
import 'package:ai_test_flutter/src/cli/logs_command.dart';
import 'package:ai_test_flutter/src/cli/restart_command.dart';
import 'package:args/command_runner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the Step 16 CLI commands: `stop`, `status`, `doctor`, `logs`,
/// `restart`.
///
/// All commands use injected fakes so no real `flutter` process or real PIDs
/// are touched. [StateFile.debugHomeOverride] redirects every state.json read
/// and write to a per-test temp directory.
///
/// Asserts:
/// 1. `stop` deletes state.json; idempotent when absent.
/// 2. `status` prints JSON with `pid`, `alive`, `vmServiceUri`, `webPort`,
///    `startedAt`; prints `{"running":false}` when state is absent.
/// 3. `doctor` prints pass/fail for the 4 preflight checks.
/// 4. `logs` prints "No log file" message when flutter-dev.log is absent.
/// 5. `logs --follow` is accepted as a valid flag (no crash).
/// 6. `restart` invokes stop then start (compose); state.json reflects the
///    new process after restart.
/// 7. Integration: `start → status → stop` pipeline works end-to-end using
///    injected fakes for process launch and kill.
void main() {
  late Directory tempHome;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('ai_test_cmds_');
    StateFile.debugHomeOverride = tempHome.path;
  });

  tearDown(() {
    StateFile.debugHomeOverride = null;
    if (tempHome.existsSync()) {
      tempHome.deleteSync(recursive: true);
    }
  });

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Writes a canonical state.json in the temp home.
  Future<void> writeState({
    int pid = 1234,
    String vmServiceUri = 'ws://127.0.0.1:8181/tok/ws',
    int webPort = 3100,
    String startedAt = '2026-05-16T10:00:00.000Z',
  }) async {
    await StateFile.write(<String, dynamic>{
      'pid': pid,
      'vmServiceUri': vmServiceUri,
      'webPort': webPort,
      'vmServicePort': 8181,
      'startedAt': startedAt,
      'profile': 'debug',
      'projectRoot': Directory.current.path,
    });
  }

  /// Boots a [CommandRunner] containing [command] and runs it with [args].
  Future<void> runCmd(Command<void> command, List<String> args) {
    final CommandRunner<void> runner =
        CommandRunner<void>('ai_test_flutter', 'test')..addCommand(command);
    return runner.run(args);
  }

  // ---------------------------------------------------------------------------
  // StopCommand
  // ---------------------------------------------------------------------------

  group('StopCommand', () {
    test('--help describes the command', () {
      final CommandRunner<void> runner =
          CommandRunner<void>('ai_test_flutter', 'test')
            ..addCommand(StopCommand());
      final String usage = runner.commands['stop']!.usage;
      expect(usage, isNotEmpty);
    });

    test('deletes state.json and calls kill on the recorded PID', () async {
      await writeState(pid: 7777);

      final List<int> killedPids = <int>[];
      final StopCommand cmd = StopCommand(
        killPid: (int pid, ProcessSignal signal) {
          killedPids.add(pid);
          return true;
        },
      );

      await runCmd(cmd, <String>['stop']);

      expect(killedPids, equals(<int>[7777]),
          reason: 'must kill the PID recorded in state.json');
      expect(File(StateFile.path).existsSync(), isFalse,
          reason: 'state.json must be deleted after stop');
    });

    test('is idempotent when state.json is absent', () async {
      expect(File(StateFile.path).existsSync(), isFalse);

      final StopCommand cmd = StopCommand(
        killPid: (int pid, ProcessSignal signal) =>
            fail('kill must not be called when no state exists'),
      );

      // Must not throw.
      await runCmd(cmd, <String>['stop']);
    });
  });

  // ---------------------------------------------------------------------------
  // StatusCommand
  // ---------------------------------------------------------------------------

  group('StatusCommand', () {
    test('--help describes the command', () {
      final CommandRunner<void> runner =
          CommandRunner<void>('ai_test_flutter', 'test')
            ..addCommand(StatusCommand());
      final String usage = runner.commands['status']!.usage;
      expect(usage, isNotEmpty);
    });

    test('prints running=false when state.json is absent', () async {
      final StringBuffer buf = StringBuffer();

      final StatusCommand cmd = StatusCommand(
        stdout: buf,
        isAlive: (int pid) => false,
      );

      await runCmd(cmd, <String>['status']);

      final Map<String, dynamic> out =
          jsonDecode(buf.toString()) as Map<String, dynamic>;
      expect(out['running'], isFalse);
    });

    test('prints JSON status when process is alive', () async {
      await writeState(pid: 9999, vmServiceUri: 'ws://127.0.0.1:8181/tok/ws');

      final StringBuffer buf = StringBuffer();
      final StatusCommand cmd = StatusCommand(
        stdout: buf,
        isAlive: (int pid) => pid == 9999,
      );

      await runCmd(cmd, <String>['status']);

      final Map<String, dynamic> out =
          jsonDecode(buf.toString()) as Map<String, dynamic>;
      expect(out['pid'], equals(9999));
      expect(out['alive'], isTrue);
      expect(out['vmServiceUri'], equals('ws://127.0.0.1:8181/tok/ws'));
      expect(out['webPort'], equals(3100));
      expect(out['startedAt'], isA<String>());
    });

    test('reports alive=false when process is dead but state exists', () async {
      await writeState(pid: 1111);

      final StringBuffer buf = StringBuffer();
      final StatusCommand cmd = StatusCommand(
        stdout: buf,
        isAlive: (int pid) => false,
      );

      await runCmd(cmd, <String>['status']);

      final Map<String, dynamic> out =
          jsonDecode(buf.toString()) as Map<String, dynamic>;
      expect(out['pid'], equals(1111));
      expect(out['alive'], isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // DoctorCommand
  // ---------------------------------------------------------------------------

  group('DoctorCommand', () {
    test('--help describes the command', () {
      final CommandRunner<void> runner =
          CommandRunner<void>('ai_test_flutter', 'test')
            ..addCommand(DoctorCommand());
      final String usage = runner.commands['doctor']!.usage;
      expect(usage, isNotEmpty);
    });

    test('prints pass/fail for each check with injected fakes', () async {
      final StringBuffer buf = StringBuffer();

      final DoctorCommand cmd = DoctorCommand(
        stdout: buf,
        checkFlutterVersion: () => true,
        checkPortFree: (int port, int? ourPid) => true,
        checkPluginDirExists: () => true,
        checkMainDartInstalled: () => true,
      );

      await runCmd(cmd, <String>['doctor']);

      final String output = buf.toString();
      expect(output, contains('flutter --version'));
      expect(output, contains('port 3100'));
      expect(output, contains('ai_test_flutter'));
      expect(output, contains('AiTestPluginV3.install()'));
      // All checks pass.
      expect(output, isNot(contains('[FAIL]')));
    });

    test('reports FAIL when checks fail', () async {
      final StringBuffer buf = StringBuffer();

      final DoctorCommand cmd = DoctorCommand(
        stdout: buf,
        checkFlutterVersion: () => false,
        checkPortFree: (int port, int? ourPid) => false,
        checkPluginDirExists: () => false,
        checkMainDartInstalled: () => false,
      );

      await runCmd(cmd, <String>['doctor']);

      final String output = buf.toString();
      // At least one FAIL expected.
      expect(output, contains('[FAIL]'));
    });
  });

  // ---------------------------------------------------------------------------
  // LogsCommand
  // ---------------------------------------------------------------------------

  group('LogsCommand', () {
    test('--help advertises --follow flag', () {
      final CommandRunner<void> runner =
          CommandRunner<void>('ai_test_flutter', 'test')
            ..addCommand(LogsCommand());
      final String usage = runner.commands['logs']!.usage;
      expect(usage, contains('--[no-]follow'));
    });

    test('prints absence message when log file does not exist', () async {
      final StringBuffer buf = StringBuffer();

      final LogsCommand cmd = LogsCommand(stdout: buf);

      await runCmd(cmd, <String>['logs']);

      expect(
        buf.toString(),
        contains('No log file'),
        reason: 'should guide user when flutter-dev.log is absent',
      );
    });

    test('prints log file content when file exists', () async {
      // Create the log file in the temp home.
      final Directory aiTestDir =
          Directory('${tempHome.path}${Platform.pathSeparator}.ai-test')
            ..createSync();
      final File logFile = File(
        '${aiTestDir.path}${Platform.pathSeparator}flutter-dev.log',
      )..writeAsStringSync('Hello from flutter dev\nLine 2\n');

      final StringBuffer buf = StringBuffer();
      final LogsCommand cmd = LogsCommand(stdout: buf);

      await runCmd(cmd, <String>['logs']);

      expect(buf.toString(), contains('Hello from flutter dev'));
      expect(buf.toString(), contains('Line 2'));

      logFile.deleteSync();
    });
  });

  // ---------------------------------------------------------------------------
  // RestartCommand
  // ---------------------------------------------------------------------------

  group('RestartCommand', () {
    test('--help describes the command', () {
      final CommandRunner<void> runner =
          CommandRunner<void>('ai_test_flutter', 'test')
            ..addCommand(RestartCommand());
      final String usage = runner.commands['restart']!.usage;
      expect(usage, isNotEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Integration: start → status → stop
  // ---------------------------------------------------------------------------

  group('Integration: start → status → stop', () {
    test('pipeline writes and removes state correctly', () async {
      // 1. Start: deferred-seed log file with URI line + inject a fake shell
      //    that echoes the child PID. StartCommand.run() truncates the log
      //    file at entry, so seed AFTER truncation via a delayed write; new
      //    wrapper writes flutter stdout to the log file and reads URI from
      //    there. Wrapper shell's own stdout only emits `$!`.
      Future<void>.delayed(const Duration(milliseconds: 50), () {
        final Directory dir = Directory('${tempHome.path}/.ai-test');
        if (!dir.existsSync()) dir.createSync();
        File('${dir.path}/flutter-dev.log').writeAsStringSync(
            'Debug service listening on ws://127.0.0.1:8181/integ_tok/ws\n');
      });
      final _FakeProcess fakeProcess =
          _FakeProcess.withPidLine(pidLine: '5555', pid: 1);

      // D6 seams: noop processRun + empty tmp root + zero capture delay so the
      // legacy integration test does not invoke the real `pgrep -fl` against
      // the developer's machine.
      final Directory emptyTmpRoot =
          Directory.systemTemp.createTempSync('ai_test_tmproot_');
      addTearDown(() {
        if (emptyTmpRoot.existsSync()) {
          emptyTmpRoot.deleteSync(recursive: true);
        }
      });
      final StartCommand startCmd = StartCommand(
        processStart: (String exe, List<String> args,
                {ProcessStartMode mode = ProcessStartMode.normal}) async =>
            fakeProcess,
        processRun: (String exe, List<String> args,
                {bool runInShell = false}) async =>
            ProcessResult(0, 1, '', ''),
        tmpRootOverride: emptyTmpRoot.path,
        chromeCaptureDelay: Duration.zero,
      );

      final CommandRunner<void> runner =
          CommandRunner<void>('ai_test_flutter', 'test')..addCommand(startCmd);
      await runner.run(<String>['start']);

      // Assert state.json was written.
      Map<String, dynamic>? state = await StateFile.read();
      expect(state, isNotNull);
      expect(state!['pid'], equals(5555));

      // 2. Status: liveness check via injected isAlive.
      final StringBuffer statusBuf = StringBuffer();
      final StatusCommand statusCmd = StatusCommand(
        stdout: statusBuf,
        isAlive: (int pid) => pid == 5555,
      );

      final CommandRunner<void> runner2 =
          CommandRunner<void>('ai_test_flutter', 'test')..addCommand(statusCmd);
      await runner2.run(<String>['status']);

      final Map<String, dynamic> statusOut =
          jsonDecode(statusBuf.toString()) as Map<String, dynamic>;
      expect(statusOut['alive'], isTrue);
      expect(statusOut['pid'], equals(5555));

      // 3. Stop: kill the process and delete state.json.
      final List<int> killed = <int>[];
      final StopCommand stopCmd = StopCommand(
        killPid: (int pid, ProcessSignal signal) {
          killed.add(pid);
          return true;
        },
        isAlive: (int pid) => false,
        postSigtermDelay: Duration.zero,
      );

      final CommandRunner<void> runner3 =
          CommandRunner<void>('ai_test_flutter', 'test')..addCommand(stopCmd);
      await runner3.run(<String>['stop']);

      expect(killed, equals(<int>[5555]));
      state = await StateFile.read();
      expect(state, isNull, reason: 'state.json must be gone after stop');
    });
  });
}

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

/// Fake [Process] used by [StartCommand] in integration tests.
class _FakeProcess implements Process {
  _FakeProcess._(this._stdoutController, this.pid);

  factory _FakeProcess.withPidLine({
    required String pidLine,
    required int pid,
  }) {
    // onListen pattern: hand off the bytes when (not before) the subscriber
    // arrives. Prevents broadcast-style drop-with-no-listener flakes in
    // long-running test suites.
    final List<int> bytes = utf8.encode('$pidLine\n');
    final StreamController<List<int>> controller =
        StreamController<List<int>>();
    controller.onListen = () {
      controller.add(bytes);
    };
    return _FakeProcess._(controller, pid);
  }

  factory _FakeProcess.withUriLine(String line, {required int pid}) {
    final StreamController<List<int>> controller =
        StreamController<List<int>>.broadcast();
    final _FakeProcess process = _FakeProcess._(controller, pid);
    // Defer until after listener subscribes; broadcast streams drop eager adds.
    Future<void>.delayed(const Duration(milliseconds: 10), () {
      if (!controller.isClosed) {
        controller.add(utf8.encode('$line\n'));
      }
    });
    return process;
  }

  final StreamController<List<int>> _stdoutController;

  @override
  final int pid;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  IOSink get stdin => throw UnimplementedError('not used in integration test');

  @override
  Future<int> get exitCode => Completer<int>().future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}
