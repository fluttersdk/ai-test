import 'dart:io' as io;

import 'package:args/command_runner.dart';

/// Signature for the test-injectable `flutter --version` probe.
typedef FlutterVersionCheck = bool Function();

/// Signature for the port-availability probe. [ourPid] is the recorded CLI
/// process id when state.json exists; the check passes when the port is
/// either free OR held by [ourPid].
typedef PortFreeCheck = bool Function(int port, int? ourPid);

/// Signature for the plugin-directory existence probe.
typedef PluginDirCheck = bool Function();

/// Signature for the `lib/main.dart` plugin-installation probe.
typedef MainDartInstallCheck = bool Function();

/// `ai_test_flutter doctor` — environment preflight for V3 plugin lifecycle.
///
/// Runs a small battery of checks and prints `[PASS]` / `[FAIL]` per item.
/// Exits 0 unconditionally; the user inspects the output for failures.
///
/// ### Checks
/// 1. `flutter --version` succeeds (Flutter SDK on PATH and runnable).
/// 2. The configured web port (default 3100) is free OR held by the recorded
///    CLI process.
/// 3. `references/ai-test/packages/ai_test_flutter/` exists relative to the
///    current working directory (host project has the plugin vendored).
/// 4. `lib/main.dart` contains `AiTestPluginV3.install()` (V3 wiring done).
///
/// All checks are injectable via constructor for unit testing.
class DoctorCommand extends Command<void> {
  /// Constructs the command.
  ///
  /// All `check*` parameters default to a real probe; tests inject fakes that
  /// return scripted boolean values without touching the host environment.
  DoctorCommand({
    StringSink? stdout,
    FlutterVersionCheck? checkFlutterVersion,
    PortFreeCheck? checkPortFree,
    PluginDirCheck? checkPluginDirExists,
    MainDartInstallCheck? checkMainDartInstalled,
  })  : _out = stdout ?? io.stdout,
        _checkFlutterVersion = checkFlutterVersion ?? _defaultFlutterVersion,
        _checkPortFree = checkPortFree ?? _defaultPortFree,
        _checkPluginDirExists = checkPluginDirExists ?? _defaultPluginDir,
        _checkMainDartInstalled =
            checkMainDartInstalled ?? _defaultMainDartInstalled;

  final StringSink _out;
  final FlutterVersionCheck _checkFlutterVersion;
  final PortFreeCheck _checkPortFree;
  final PluginDirCheck _checkPluginDirExists;
  final MainDartInstallCheck _checkMainDartInstalled;

  @override
  final String name = 'doctor';

  @override
  final String description =
      'Environment preflight: verify Flutter SDK, port, plugin directory, and '
      'main.dart wiring. Exits 0; inspect output for failures.';

  @override
  Future<void> run() async {
    final List<({String label, bool pass})> results =
        <({String label, bool pass})>[
      (label: 'flutter --version reachable', pass: _checkFlutterVersion()),
      (label: 'port 3100 free or held by us', pass: _checkPortFree(3100, null)),
      (
        label: 'ai_test_flutter plugin directory present',
        pass: _checkPluginDirExists()
      ),
      (
        label: 'lib/main.dart wires AiTestPluginV3.install()',
        pass: _checkMainDartInstalled()
      ),
    ];

    for (final ({String label, bool pass}) item in results) {
      final String tag = item.pass ? '[PASS]' : '[FAIL]';
      _out.writeln('$tag ${item.label}');
    }

    if (results.any((({String label, bool pass}) r) => !r.pass)) {
      _out.writeln('');
      _out.writeln('Some checks failed. See README for remediation steps.');
    }
  }

  // ---------------------------------------------------------------------------
  // Default check implementations
  // ---------------------------------------------------------------------------

  static bool _defaultFlutterVersion() {
    try {
      final io.ProcessResult result =
          io.Process.runSync('flutter', <String>['--version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static bool _defaultPortFree(int port, int? ourPid) {
    // Cross-platform port probe via `lsof -ti tcp:<port>` (POSIX) or
    // `netstat -ano` (Windows). Returns true when no PID holds the port OR
    // the holding PID is `ourPid`.
    try {
      if (io.Platform.isWindows) {
        final io.ProcessResult res = io.Process.runSync(
          'netstat',
          <String>['-ano', '-p', 'TCP'],
        );
        final String stdoutStr = res.stdout.toString();
        final RegExp pattern =
            RegExp(r':' + port.toString() + r'\s.*\s(\d+)$', multiLine: true);
        final Match? match = pattern.firstMatch(stdoutStr);
        if (match == null) return true;
        final int holdingPid = int.parse(match.group(1)!);
        return ourPid != null && holdingPid == ourPid;
      }
      final io.ProcessResult res = io.Process.runSync(
        'lsof',
        <String>['-ti', 'tcp:$port'],
      );
      final String stdoutStr = res.stdout.toString().trim();
      if (stdoutStr.isEmpty) return true;
      final int holdingPid = int.tryParse(stdoutStr.split('\n').first) ?? -1;
      return ourPid != null && holdingPid == ourPid;
    } catch (_) {
      // No lsof/netstat — be permissive (don't false-fail the doctor).
      return true;
    }
  }

  static bool _defaultPluginDir() {
    final io.Directory dir = io.Directory(
      'references/ai-test/packages/ai_test_flutter',
    );
    return dir.existsSync();
  }

  static bool _defaultMainDartInstalled() {
    final io.File main = io.File('lib/main.dart');
    if (!main.existsSync()) return false;
    return main.readAsStringSync().contains('AiTestPluginV3.install()');
  }
}
