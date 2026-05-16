@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_test_flutter/src/cli/start_command.dart';
import 'package:ai_test_flutter/src/cli/state_file.dart';
import 'package:args/command_runner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for [StartCommand] (Step 15 of V3 plan).
///
/// `StartCommand` spawns `flutter run -d chrome`, scrapes the VM service URI
/// from stdout, and writes `~/.ai-test/state.json`. We inject a fake
/// `Process.start` via the constructor hook so no real `flutter` is launched.
///
/// Asserts:
/// 1. `--help` lists every option (`--port`, `--vm-service-port`, `--no-dds`,
///    `--profile-static`) with sane defaults.
/// 2. `run()` invokes the launcher with the Wave 1 amended flag set: includes
///    `-d chrome`, `--no-dds`, `--dart-define=AI_TEST=1`, `--web-port=<port>`;
///    excludes `--disable-service-auth-codes` and `--dart-vm-flags`.
/// 3. `run()` scrapes the VM service URI from stdout and writes state.json
///    with all 7 required keys.
/// 4. `run()` times out cleanly when stdout never emits the URI line.
/// Default `processRun` for legacy tests that don't exercise D6 reaper /
/// capture behavior — every Process.run probe returns "exit code 1, empty
/// stdout" so the reaper finds nothing and the Chrome capture degrades to
/// null. Without this seam the legacy tests would invoke the real
/// `pgrep -fl flutter_tools_chrome_device` on the developer's machine and
/// SIGKILL real Chrome instances.
Future<ProcessResult> _noopProcessRun(
  String executable,
  List<String> arguments, {
  bool runInShell = false,
}) async =>
    ProcessResult(0, 1, '', '');

void main() {
  late Directory tempHome;
  late Directory emptyTmpRoot;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('ai_test_start_');
    emptyTmpRoot = Directory.systemTemp.createTempSync('ai_test_tmproot_');
    StateFile.debugHomeOverride = tempHome.path;
  });

  tearDown(() {
    StateFile.debugHomeOverride = null;
    if (tempHome.existsSync()) {
      tempHome.deleteSync(recursive: true);
    }
    if (emptyTmpRoot.existsSync()) {
      emptyTmpRoot.deleteSync(recursive: true);
    }
  });

  group('StartCommand argument parsing', () {
    test('--help advertises every option with sane defaults', () {
      final CommandRunner<void> runner =
          CommandRunner<void>('ai_test_flutter', 'test runner')
            ..addCommand(StartCommand());

      final String usage = runner.commands['start']!.usage;

      expect(usage, contains('--port'));
      expect(usage, contains('3100'));
      expect(usage, contains('--vm-service-port'));
      expect(usage, contains('8181'));
      expect(usage, contains('--[no-]dds'));
      expect(usage, contains('--[no-]profile-static'));
    });
  });

  group('StartCommand.run', () {
    test('wraps flutter run in nohup via sh -c with Wave 1 amended flags',
        () async {
      late String capturedExecutable;
      late List<String> capturedArgs;
      _seedLogFile(tempHome,
          'Debug service listening on ws://127.0.0.1:8181/abc123token/ws\n');
      final _FakeProcess fake =
          _FakeProcess.withPidLine(pidLine: '4242', pid: 1);

      final StartCommand command = StartCommand(
        processStart: (String executable, List<String> args,
            {ProcessStartMode mode = ProcessStartMode.normal}) async {
          capturedExecutable = executable;
          capturedArgs = args;
          return fake;
        },
        processRun: _noopProcessRun,
        tmpRootOverride: emptyTmpRoot.path,
        chromeCaptureDelay: Duration.zero,
      );

      await _runCommand(command, <String>['start']);

      expect(capturedExecutable, equals('sh'),
          reason: 'wraps via sh -c so the child survives the CLI exit');
      expect(capturedArgs.first, equals('-c'));
      final String shellCmd = capturedArgs[1];
      expect(shellCmd, contains('nohup flutter run -d chrome'));
      expect(shellCmd, contains('--no-dds'));
      expect(shellCmd, contains('--dart-define=AI_TEST=1'));
      expect(shellCmd, contains('--web-port=3100'));
      expect(shellCmd, isNot(contains('--disable-service-auth-codes')),
          reason: 'Wave 1 spike: Flutter 3.41 rejects this flag');
      expect(shellCmd, isNot(contains('--dart-vm-flags')),
          reason: 'Wave 1 spike: Flutter 3.41 rejects this flag');
      expect(shellCmd, contains(r'</dev/null'),
          reason: 'must detach stdin so SIGPIPE never fires');
      expect(shellCmd, contains(r'echo $!'),
          reason: 'wrapper echoes background PID on its stdout');
    });

    test('scrapes URI from log file and writes state.json with PID', () async {
      _seedLogFile(
          tempHome,
          'Launching lib/main.dart on Chrome in debug mode...\n'
          'Debug service listening on '
          'ws://127.0.0.1:8181/abc123token/ws\n');
      final _FakeProcess fake =
          _FakeProcess.withPidLine(pidLine: '9999', pid: 1);

      final StartCommand command = StartCommand(
        processStart: (String executable, List<String> args,
                {ProcessStartMode mode = ProcessStartMode.normal}) async =>
            fake,
        processRun: _noopProcessRun,
        tmpRootOverride: emptyTmpRoot.path,
        chromeCaptureDelay: Duration.zero,
      );

      await _runCommand(command, <String>['start', '--port=3199']);

      final Map<String, dynamic>? state = await StateFile.read();
      expect(state, isNotNull);
      expect(state!['pid'], equals(9999));
      expect(
          state['vmServiceUri'], equals('ws://127.0.0.1:8181/abc123token/ws'));
      expect(state['webPort'], equals(3199));
      expect(state['vmServicePort'], equals(8181));
      expect(state['profile'], equals('debug'));
      expect(state['startedAt'], isA<String>());
      expect(state['projectRoot'], isA<String>());
      expect(
          () => DateTime.parse(state['startedAt'] as String), returnsNormally);
    });

    test('--profile-static flips the recorded profile to "static"', () async {
      _seedLogFile(
          tempHome, 'Debug service listening on ws://127.0.0.1:8181/tok/ws\n');
      final _FakeProcess fake = _FakeProcess.withPidLine(pidLine: '1', pid: 1);

      final StartCommand command = StartCommand(
        processStart: (String executable, List<String> args,
                {ProcessStartMode mode = ProcessStartMode.normal}) async =>
            fake,
        processRun: _noopProcessRun,
        tmpRootOverride: emptyTmpRoot.path,
        chromeCaptureDelay: Duration.zero,
      );

      await _runCommand(command, <String>['start', '--profile-static']);

      final Map<String, dynamic> state = (await StateFile.read())!;
      expect(state['profile'], equals('static'));
    });

    test('throws UsageException when log never yields the URI line', () async {
      // Seed an empty log file so the scraper polls and times out cleanly.
      _seedLogFile(tempHome, 'still booting...\n');
      final _FakeProcess fake = _FakeProcess.withPidLine(pidLine: '7', pid: 1);

      final StartCommand command = StartCommand(
        processStart: (String executable, List<String> args,
                {ProcessStartMode mode = ProcessStartMode.normal}) async =>
            fake,
        processRun: _noopProcessRun,
        tmpRootOverride: emptyTmpRoot.path,
        chromeCaptureDelay: Duration.zero,
        uriScrapeTimeout: const Duration(milliseconds: 200),
      );

      expect(
        () => _runCommand(command, <String>['start']),
        throwsA(isA<UsageException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // D6 Layer 1: pre-flight reaper
  // ---------------------------------------------------------------------------
  group('StartCommand D6 Layer 1: pre-flight reaper', () {
    test(
        'pgrep returns PIDs → reaper SIGKILLs each + deletes matching tmp dirs',
        () async {
      // Pre-seed two orphan tmp dirs into the synthetic tmpRoot — the reaper
      // must walk the tree (flutter_tools.*/flutter_tools_chrome_device.*)
      // and delete each child.
      final Directory tmpRoot =
          Directory.systemTemp.createTempSync('ai_test_tmproot_');
      final Directory parent1 = Directory('${tmpRoot.path}/flutter_tools.aaa')
        ..createSync();
      final Directory orphan1 =
          Directory('${parent1.path}/flutter_tools_chrome_device.xxx')
            ..createSync();
      File('${orphan1.path}/marker.txt').writeAsStringSync('garbage');
      final Directory parent2 = Directory('${tmpRoot.path}/flutter_tools.bbb')
        ..createSync();
      final Directory orphan2 =
          Directory('${parent2.path}/flutter_tools_chrome_device.yyy')
            ..createSync();
      File('${orphan2.path}/marker.txt').writeAsStringSync('garbage');

      final List<(int, ProcessSignal)> kills = <(int, ProcessSignal)>[];
      final List<List<String>> runs = <List<String>>[];

      // Deferred URI seed so the scraper completes.
      _seedLogFile(tempHome,
          'Debug service listening on ws://127.0.0.1:8181/reaped_tok/ws\n');
      final _FakeProcess fake =
          _FakeProcess.withPidLine(pidLine: '4242', pid: 1);

      final StartCommand command = StartCommand(
        processStart: (String executable, List<String> args,
                {ProcessStartMode mode = ProcessStartMode.normal}) async =>
            fake,
        processRun: (String exe, List<String> args,
            {bool runInShell = false}) async {
          runs.add(<String>[exe, ...args]);
          if (exe == 'pgrep' &&
              args.contains('-fl') &&
              args.contains('flutter_tools_chrome_device')) {
            // Two orphan PIDs returned, paired with command-line strings as
            // `-fl` does.
            return ProcessResult(
              0,
              0,
              '11111 chrome --user-data-dir=/x/flutter_tools_chrome_device.aaa\n'
                  '22222 chrome --user-data-dir=/y/flutter_tools_chrome_device.bbb',
              '',
            );
          }
          // No live capture in this test — return empty so capture writes null.
          return ProcessResult(0, 1, '', '');
        },
        killPid: (int pid, ProcessSignal signal) {
          kills.add((pid, signal));
          return true;
        },
        tmpRootOverride: tmpRoot.path,
        chromeCaptureDelay: Duration.zero,
      );

      try {
        await _runCommand(command, <String>['start']);

        // Verify pgrep invoked with the expected arguments (deep equality —
        // List<String> equality is structural via the equals matcher).
        expect(
            runs,
            anyElement(equals(<String>[
              'pgrep',
              '-fl',
              'flutter_tools_chrome_device',
            ])));
        // Both orphan PIDs SIGKILLed.
        expect(
            kills,
            containsAll(<(int, ProcessSignal)>[
              (11111, ProcessSignal.sigkill),
              (22222, ProcessSignal.sigkill),
            ]));
        // Both orphan tmp dirs removed.
        expect(orphan1.existsSync(), isFalse);
        expect(orphan2.existsSync(), isFalse);
      } finally {
        if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
      }
    });

    test('reaper is non-fatal when pgrep exits non-zero (no orphans found)',
        () async {
      final Directory tmpRoot =
          Directory.systemTemp.createTempSync('ai_test_tmproot_');
      _seedLogFile(tempHome,
          'Debug service listening on ws://127.0.0.1:8181/clean_tok/ws\n');
      final _FakeProcess fake = _FakeProcess.withPidLine(pidLine: '7', pid: 1);

      final StartCommand command = StartCommand(
        processStart: (String executable, List<String> args,
                {ProcessStartMode mode = ProcessStartMode.normal}) async =>
            fake,
        processRun: (String exe, List<String> args,
                {bool runInShell = false}) async =>
            // pgrep returns exit code 1 + empty stdout when no matches.
            ProcessResult(0, 1, '', ''),
        killPid: (int pid, ProcessSignal signal) =>
            fail('no PID should be killed when pgrep finds nothing'),
        tmpRootOverride: tmpRoot.path,
        chromeCaptureDelay: Duration.zero,
      );

      try {
        await _runCommand(command, <String>['start']);
        // Must reach the state-write phase — start did not abort on the empty
        // reaper result.
        final Map<String, dynamic>? state = await StateFile.read();
        expect(state, isNotNull);
        expect(state!['pid'], equals(7));
      } finally {
        if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // D6 Layer 2: Chrome PID + tmpProfileDir capture
  // ---------------------------------------------------------------------------
  group('StartCommand D6 Layer 2: Chrome PID + tmpProfileDir capture', () {
    test('pgrep -P + ps -o command= → state captures chromePid + tmpProfileDir',
        () async {
      final Directory tmpRoot =
          Directory.systemTemp.createTempSync('ai_test_tmproot_');
      _seedLogFile(tempHome,
          'Debug service listening on ws://127.0.0.1:8181/cap_tok/ws\n');
      final _FakeProcess fake =
          _FakeProcess.withPidLine(pidLine: '8888', pid: 1);

      final StartCommand command = StartCommand(
        processStart: (String executable, List<String> args,
                {ProcessStartMode mode = ProcessStartMode.normal}) async =>
            fake,
        processRun: (String exe, List<String> args,
            {bool runInShell = false}) async {
          // Reaper pgrep -fl: no orphans (clean slate).
          if (exe == 'pgrep' && args.contains('-fl')) {
            return ProcessResult(0, 1, '', '');
          }
          // Capture pgrep -P 8888: two children — frontend_server + Chrome.
          if (exe == 'pgrep' && args.contains('-P') && args.contains('8888')) {
            return ProcessResult(0, 0, '9001\n9002\n', '');
          }
          // ps -p 9001: frontend_server (not Chrome, skip).
          if (exe == 'ps' && args.contains('9001')) {
            return ProcessResult(
              0,
              0,
              '/usr/bin/dart /flutter/bin/cache/dart-sdk/snapshots/'
                  'frontend_server.dart.snapshot --sdk-root /flutter/web_sdk\n',
              '',
            );
          }
          // ps -p 9002: Chrome with the user-data-dir argument we want.
          if (exe == 'ps' && args.contains('9002')) {
            return ProcessResult(
              0,
              0,
              '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome '
                  '--user-data-dir=/var/folders/x/y/T/flutter_tools.ABC/'
                  'flutter_tools_chrome_device.DEF '
                  '--remote-debugging-port=12345 '
                  'http://localhost:3100\n',
              '',
            );
          }
          return ProcessResult(0, 1, '', '');
        },
        killPid: (int pid, ProcessSignal signal) => true,
        tmpRootOverride: tmpRoot.path,
        chromeCaptureDelay: Duration.zero,
      );

      try {
        await _runCommand(command, <String>['start']);

        final Map<String, dynamic> state = (await StateFile.read())!;
        expect(state['pid'], equals(8888));
        expect(state['chromePid'], equals(9002),
            reason: 'second child whose ps command matches '
                'flutter_tools_chrome_device wins');
        expect(
            state['tmpProfileDir'],
            equals('/var/folders/x/y/T/flutter_tools.ABC/'
                'flutter_tools_chrome_device.DEF'),
            reason: '--user-data-dir substring extracted into state');
      } finally {
        if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
      }
    });

    test('capture writes null chromePid + tmpProfileDir when no Chrome child',
        () async {
      final Directory tmpRoot =
          Directory.systemTemp.createTempSync('ai_test_tmproot_');
      _seedLogFile(tempHome,
          'Debug service listening on ws://127.0.0.1:8181/nochrome_tok/ws\n');
      final _FakeProcess fake = _FakeProcess.withPidLine(pidLine: '1', pid: 1);

      final StartCommand command = StartCommand(
        processStart: (String executable, List<String> args,
                {ProcessStartMode mode = ProcessStartMode.normal}) async =>
            fake,
        processRun: (String exe, List<String> args,
                {bool runInShell = false}) async =>
            // Every probe returns "no matches": reaper, pgrep -P, and the
            // fallback pgrep -fl after capture-failure all see exit=1.
            ProcessResult(0, 1, '', ''),
        killPid: (int pid, ProcessSignal signal) => true,
        tmpRootOverride: tmpRoot.path,
        chromeCaptureDelay: Duration.zero,
      );

      try {
        await _runCommand(command, <String>['start']);

        final Map<String, dynamic> state = (await StateFile.read())!;
        expect(state['chromePid'], isNull,
            reason: 'capture failure surfaces as null, not absent key');
        expect(state['tmpProfileDir'], isNull);
        // State must still contain the chromePid key (with null) so legacy vs.
        // capture-failure remain distinguishable downstream.
        expect(state.containsKey('chromePid'), isTrue);
        expect(state.containsKey('tmpProfileDir'), isTrue);
      } finally {
        if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
      }
    });
  });
}

/// Schedules a deferred write of `~/.ai-test/flutter-dev.log` under the temp
/// home. StartCommand.run() truncates the file at the start of its body, so
/// the seed must happen AFTER that truncation; ~50 ms gives StartCommand
/// time to enter its polling loop before the URI line appears.
void _seedLogFile(Directory tempHome, String content) {
  Future<void>.delayed(const Duration(milliseconds: 50), () {
    final Directory dir = Directory('${tempHome.path}/.ai-test');
    if (!dir.existsSync()) dir.createSync();
    File('${dir.path}/flutter-dev.log').writeAsStringSync(content);
  });
}

/// Boots a [CommandRunner] with `command` and invokes it with `args`.
Future<void> _runCommand(Command<void> command, List<String> args) {
  final CommandRunner<void> runner =
      CommandRunner<void>('ai_test_flutter', 'test runner')
        ..addCommand(command);
  return runner.run(args);
}

/// Test double for [Process] used as the return value of the injected
/// `processStart` hook. Emits a scripted stdout sequence and never exits.
class _FakeProcess implements Process {
  _FakeProcess._(this._stdoutController, this.pid);

  /// Fake the wrapper shell stdout: echoes the supplied PID line so
  /// [StartCommand._scrapeChildPid] resolves. Buffers the bytes inside a
  /// late single-subscription stream — this hands the line off only AFTER
  /// the scraper has subscribed, so the value never races against
  /// broadcast-style drop-with-no-listener semantics.
  factory _FakeProcess.withPidLine({
    required String pidLine,
    required int pid,
  }) {
    final List<int> bytes = utf8.encode('$pidLine\n');
    final StreamController<List<int>> controller =
        StreamController<List<int>>();
    controller.onListen = () {
      controller.add(bytes);
    };
    return _FakeProcess._(controller, pid);
  }

  factory _FakeProcess.silent({required int pid}) {
    return _FakeProcess._(StreamController<List<int>>.broadcast(), pid);
  }

  final StreamController<List<int>> _stdoutController;

  @override
  final int pid;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  IOSink get stdin => throw UnimplementedError('not used by StartCommand');

  @override
  Future<int> get exitCode => Completer<int>().future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}
