import 'dart:convert';
import 'dart:io' as io;

import 'package:args/command_runner.dart';

import 'state_file.dart';

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

/// Signature for the hot-restart staleness probe.
///
/// Returns `true` when the recorded `state.json.startedAt` is consistent
/// with the live flutter process (no hot-restart drift detected). Returns
/// `false` when the live process appears to have restarted after the CLI
/// recorded `startedAt + drift`, meaning the MCP server's cached isolateId
/// would point at a stale isolate.
///
/// Defaults to a probe that reads state.json + queries the process's start
/// time via `ps -o lstart -p <pid>` (POSIX) / `wmic process` (Windows).
typedef StalenessCheck = bool Function();

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
    StalenessCheck? checkStaleness,
  })  : _out = stdout ?? io.stdout,
        _checkFlutterVersion = checkFlutterVersion ?? _defaultFlutterVersion,
        _checkPortFree = checkPortFree ?? _defaultPortFree,
        _checkPluginDirExists = checkPluginDirExists ?? _defaultPluginDir,
        _checkMainDartInstalled =
            checkMainDartInstalled ?? _defaultMainDartInstalled,
        _checkStaleness = checkStaleness ?? _defaultStaleness;

  final StringSink _out;
  final FlutterVersionCheck _checkFlutterVersion;
  final PortFreeCheck _checkPortFree;
  final PluginDirCheck _checkPluginDirExists;
  final MainDartInstallCheck _checkMainDartInstalled;
  final StalenessCheck _checkStaleness;

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
      (
        label: 'no hot-restart drift since CLI start (restart CLI if FAIL)',
        pass: _checkStaleness()
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

  /// Hot-restart staleness probe (Plan Risks Accepted §6).
  ///
  /// Compares `state.json.startedAt` against the live flutter process's
  /// actual start time. The MCP server caches isolateId across calls; after
  /// a hot-restart the cached id points at the dead isolate, causing
  /// phantom MethodNotFound errors.
  ///
  /// Drift threshold: 30 s. The flutter process may start a couple of
  /// seconds before the CLI writes state.json (URI scrape latency), so we
  /// only fail when the live process is *newer* than `startedAt + 30 s` —
  /// signal that a hot-restart created a fresh process post-CLI-start.
  ///
  /// Returns `true` (PASS) when state.json is absent (nothing to compare),
  /// when the staleness probe fails (no `ps` available — default-permissive),
  /// or when no drift is detected. Returns `false` (FAIL) only when drift
  /// > 30 s is observed; the doctor message tells the operator to restart
  /// the CLI for a fresh extension table.
  static bool _defaultStaleness() {
    try {
      final io.File stateFile = io.File(StateFile.path);
      if (!stateFile.existsSync()) return true;
      final Map<String, dynamic> state = jsonDecode(
        stateFile.readAsStringSync(),
      ) as Map<String, dynamic>;
      final String? startedAtIso = state['startedAt'] as String?;
      final int? pid = state['pid'] as int?;
      if (startedAtIso == null || pid == null) return true;
      final DateTime startedAt = DateTime.parse(startedAtIso);
      final DateTime? processStart = _processStartTime(pid);
      if (processStart == null) return true;
      final Duration drift = processStart.difference(startedAt);
      return drift.inSeconds <= 30;
    } catch (_) {
      // Be permissive on any parse / probe failure — don't false-fail.
      return true;
    }
  }

  static DateTime? _processStartTime(int pid) {
    try {
      if (io.Platform.isWindows) {
        // wmic returns CreationDate as YYYYMMDDHHMMSS.ffffff+TZ.
        final io.ProcessResult res = io.Process.runSync(
          'wmic',
          <String>['process', 'where', 'ProcessId=$pid', 'get', 'CreationDate'],
        );
        final String raw = res.stdout.toString().trim();
        final RegExp pattern = RegExp(r'(\d{14})');
        final Match? match = pattern.firstMatch(raw);
        if (match == null) return null;
        final String ts = match.group(1)!;
        return DateTime.utc(
          int.parse(ts.substring(0, 4)),
          int.parse(ts.substring(4, 6)),
          int.parse(ts.substring(6, 8)),
          int.parse(ts.substring(8, 10)),
          int.parse(ts.substring(10, 12)),
          int.parse(ts.substring(12, 14)),
        );
      }
      // POSIX: `ps -o lstart=` emits e.g. "Fri May 16 14:30:25 2026".
      // DateTime.tryParse only handles ISO 8601, so we parse manually.
      final io.ProcessResult res = io.Process.runSync(
        'ps',
        <String>['-o', 'lstart=', '-p', '$pid'],
      );
      final String raw = res.stdout.toString().trim();
      if (raw.isEmpty) return null;
      return _parsePsLstart(raw);
    } catch (_) {
      return null;
    }
  }

  static const Map<String, int> _monthMap = <String, int>{
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };

  /// Parses `ps -o lstart=` output ("Fri May 16 14:30:25 2026") to local
  /// DateTime. Returns null on any parse failure.
  static DateTime? _parsePsLstart(String raw) {
    try {
      final RegExp pattern = RegExp(
        r'^\w{3}\s+(\w{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(\d{4})',
      );
      final Match? m = pattern.firstMatch(raw);
      if (m == null) return null;
      final int? month = _monthMap[m.group(1)!];
      if (month == null) return null;
      return DateTime(
        int.parse(m.group(6)!),
        month,
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        int.parse(m.group(4)!),
        int.parse(m.group(5)!),
      );
    } catch (_) {
      return null;
    }
  }
}
