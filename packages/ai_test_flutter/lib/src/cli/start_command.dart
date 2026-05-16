import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import 'state_file.dart';

/// Signature for the test-injectable `Process.start` hook.
///
/// Mirrors [Process.start] so production code passes `Process.start` directly
/// and tests pass a fake that returns a scripted [Process] double. Dart does
/// not support mocking top-level functions, so this typedef is the seam.
typedef ProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  ProcessStartMode mode,
});

/// Signature for the test-injectable `Process.run` hook.
///
/// Mirrors [Process.run] enough for the D6 pgrep + ps probes; production code
/// passes `Process.run` directly while tests return scripted [ProcessResult]
/// objects per (executable, args) tuple.
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  bool runInShell,
});

/// Signature for the test-injectable `Process.killPid` hook used by the D6
/// pre-flight reaper.
typedef KillFunction = bool Function(int pid, ProcessSignal signal);

/// `ai_test_flutter start` — spawns `flutter run -d chrome` detached, scrapes
/// the VM service URI from stdout, and records the result to
/// `~/.ai-test/state.json` for downstream commands and the MCP server.
///
/// Flag set is the Wave 1 spike amendment (Flutter 3.41+ rejects the original
/// `--disable-service-auth-codes` and `--dart-vm-flags` from the planner's
/// description). The active set is:
///
/// ```
/// flutter run -d chrome \
///   --web-port=<port> \
///   --no-dds \
///   --dart-define=AI_TEST=1
/// ```
///
/// Auth code embedding lives inside the scraped URI (`ws://host:port/<token>/ws`)
/// so no launcher-level auth-disable is needed.
///
/// The process is started in [ProcessStartMode.detachedWithStdio] so the CLI
/// can return after the URI scrape while `flutter run` keeps running as a
/// detached process owned by the OS.
///
/// ### D6 GC layers
/// - **Layer 1 (pre-flight reaper)**: before the spawn, the command runs
///   `pgrep -fl flutter_tools_chrome_device` and SIGKILLs every matching PID,
///   then walks the OS temp tree and removes every orphaned
///   `flutter_tools_chrome_device.<random>` profile dir. All reaper failures
///   are swallowed and logged to stderr — they never block start.
/// - **Layer 2 (Chrome PID + tmpProfileDir capture)**: after the URI scrape,
///   the command runs `pgrep -P <flutterPid>` to enumerate Flutter's direct
///   children, then `ps -p <child> -o command=` to find the Chrome process
///   (whose command line contains `--user-data-dir=*flutter_tools_chrome_device*`).
///   The Chrome PID and extracted profile path land in `state.json` so the
///   matching `StopCommand` can apply a deterministic dual-PID cascade.
/// - **Layer 3 (state schema)**: `state.json` now carries `chromePid: int?`
///   and `tmpProfileDir: String?`. Legacy reads return null for both (the
///   `StopCommand` then logs that GC is degraded for that session).
///
/// Windows is unsupported by the reaper (no `pgrep`) — the command skips
/// Layer 1 + Layer 2 on Windows and prints a manual `taskkill /T /F` hint.
class StartCommand extends Command<void> {
  /// Constructs the command.
  ///
  /// [processStart] defaults to [Process.start]; [processRun] defaults to
  /// [Process.run]; [killPid] defaults to [Process.killPid]. Tests inject
  /// fakes for all three.
  ///
  /// [uriScrapeTimeout] caps how long the command waits on stdout for the
  /// `Debug service listening on` line — exceeding it throws a [UsageException]
  /// so the user sees a clear error instead of a hung CLI.
  ///
  /// [chromeCaptureDelay] is the wall-clock gap between the URI scrape and the
  /// `pgrep -P` capture probe; Flutter typically takes ~3s to fork Chrome
  /// after the dev server is ready. Tests pass `Duration.zero` to skip.
  ///
  /// [tmpRootOverride] redirects the reaper's profile-dir glob to a per-test
  /// directory. Production leaves it null (uses the real OS temp root: macOS
  /// walks `/var/folders/*/T/*`, Linux walks `/tmp`).
  StartCommand({
    ProcessStarter? processStart,
    ProcessRunner? processRun,
    KillFunction? killPid,
    this.uriScrapeTimeout = const Duration(seconds: 90),
    this.chromeCaptureDelay = const Duration(seconds: 3),
    this.tmpRootOverride,
  })  : _processStart = processStart ?? Process.start,
        _processRun = processRun ?? Process.run,
        _killPid = killPid ?? Process.killPid {
    argParser
      ..addOption(
        'port',
        defaultsTo: '3100',
        help: 'Web port for the Flutter dev server (forwarded as --web-port).',
      )
      ..addOption(
        'vm-service-port',
        defaultsTo: '8181',
        help: 'Recorded VM service port (informational; the scraped URI is '
            'authoritative).',
      )
      ..addFlag(
        'dds',
        defaultsTo: false,
        negatable: true,
        help: 'Enable Dart DevTools Service (DDS). Default off — Wave 1 '
            'spike confirmed bare-name ext.aitest.* calls work on Flutter '
            '3.41+ without DDS, and --no-dds reduces one connection hop. '
            'Pass --dds to opt back into DDS (useful when sharing a session '
            'with Flutter DevTools).',
      )
      ..addFlag(
        'profile-static',
        defaultsTo: false,
        negatable: true,
        help: 'Record profile=static in state.json (for serving a pre-built '
            'bundle rather than the dev server).',
      );
  }

  /// Pattern matching the Flutter dev-server stdout line that exposes the VM
  /// service WebSocket URI, e.g.
  /// `Debug service listening on ws://127.0.0.1:8181/<token>/ws`.
  static final RegExp _uriPattern = RegExp(
    r'Debug service listening on\s+(ws://\S+)',
  );

  /// Extracts the `--user-data-dir=<path>` substring from a Chrome command
  /// line. Path stops at the next whitespace (Chrome never wraps paths in
  /// quotes — argv is space-delimited by `ps -o command=`).
  static final RegExp _userDataDirPattern = RegExp(
    r'--user-data-dir=(\S+)',
  );

  /// Marker that disambiguates Flutter's Chrome from any other browser process
  /// in the user's session. Used by both the reaper (filter `pgrep -fl`
  /// output) and the capture step (filter `ps -o command=` output).
  static const String _chromeProfileMarker = 'flutter_tools_chrome_device';

  /// Max wait between process start and the URI scrape line on stdout.
  final Duration uriScrapeTimeout;

  /// Delay between the URI scrape and the Chrome PID capture probe.
  final Duration chromeCaptureDelay;

  /// When non-null, overrides the OS temp root the reaper walks for orphan
  /// `flutter_tools_chrome_device.*` profile directories. Tests use this to
  /// point at a per-test temp dir so they never touch the developer's real
  /// `/var/folders` or `/tmp`.
  final String? tmpRootOverride;

  final ProcessStarter _processStart;
  final ProcessRunner _processRun;
  final KillFunction _killPid;

  @override
  final String name = 'start';

  @override
  final String description =
      'Boot `flutter run -d chrome` detached and record the VM service URI to '
      '~/.ai-test/state.json.';

  @override
  Future<void> run() async {
    final ArgResults parsed = argResults!;
    final int webPort = int.parse(parsed['port'] as String);
    final int vmServicePort = int.parse(parsed['vm-service-port'] as String);
    final bool ddsOn = parsed['dds'] as bool;
    final bool profileStatic = parsed['profile-static'] as bool;

    // 1. D6 Layer 1 — pre-flight reaper. Non-fatal; failures are warnings only.
    //    Skipped on Windows because `pgrep` is POSIX-only; document the
    //    `taskkill /T /F` workaround for Windows operators.
    if (Platform.isWindows) {
      stderr.writeln(
        'ai_test_flutter start: D6 reaper skipped on Windows. '
        'Clean orphan Chrome instances manually with '
        '`taskkill /T /F /IM chrome.exe` after a failed session.',
      );
    } else {
      await _reapOrphans();
    }

    // 2. Prepare the log file. flutter run's stdout/stderr stream here so
    //    `ai_test_flutter logs --follow` can tail it after the CLI returns,
    //    AND so the spawn can fully detach from the CLI's stdio (no pipe
    //    keeps the parent alive). Truncated on every start.
    final File logFile = File(_logPath());
    await logFile.parent.create(recursive: true);
    await logFile.writeAsString('');

    // 3. Build the launcher argv — Wave 1 amended set only.
    final List<String> flutterArgs = <String>[
      'run',
      '-d',
      'chrome',
      '--web-port=$webPort',
      if (!ddsOn) '--no-dds',
      '--dart-define=AI_TEST=1',
    ];

    // 4. Spawn through `nohup` so the child survives the CLI's exit. On
    //    macOS, `Process.start(..., mode: ProcessStartMode.detachedWithStdio)`
    //    keeps the pipe ends owned by the parent — once the CLI returns and
    //    its FDs close, the child gets SIGPIPE on the next stdout write and
    //    dies. nohup + shell redirection breaks the pipe ownership chain.
    //    Tests inject a fake via [processStart] that bypasses this wrapper.
    final List<String> wrapperArgs = <String>[
      'nohup',
      'flutter',
      ...flutterArgs,
    ];
    final Process process = await _processStart(
      'sh',
      <String>[
        '-c',
        // Redirect all three streams to the log file, then exec the wrapper.
        // `>>` instead of `>` because we want appends (truncation already
        // happened above so we still start clean).
        '${_shellQuote(wrapperArgs)} </dev/null >>${_shellQuote([
              logFile.path,
            ])} 2>&1 & echo \$!',
      ],
      mode: ProcessStartMode.detachedWithStdio,
    );

    // 5. The shell wrapper echoes the child PID on its (very short) stdout.
    final int childPid = await _scrapeChildPid(process);

    // 6. Tail the log file for the VM service URI (timeout-guarded). Reading
    //    from the file decouples from the wrapper process lifetime.
    final String vmServiceUri = await _scrapeVmServiceUriFromFile(logFile);

    // 7. D6 Layer 2 — Chrome PID + tmpProfileDir capture. Best-effort; null
    //    fallbacks degrade the next StopCommand to flutter-only kill (with a
    //    warning). Skipped on Windows.
    int? chromePid;
    String? tmpProfileDir;
    if (!Platform.isWindows) {
      final _ChromeCapture capture = await _captureChrome(childPid);
      chromePid = capture.pid;
      tmpProfileDir = capture.tmpProfileDir;
    }

    // 8. Persist state.json atomically.
    await StateFile.write(<String, dynamic>{
      'pid': childPid,
      'vmServiceUri': vmServiceUri,
      'webPort': webPort,
      'vmServicePort': vmServicePort,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'profile': profileStatic ? 'static' : 'debug',
      'projectRoot': Directory.current.path,
      // D6: nullable fields land as JSON null when capture fails. The keys
      // are always present so consumers can distinguish "capture failure"
      // from "legacy state".
      'chromePid': chromePid,
      'tmpProfileDir': tmpProfileDir,
    });

    stdout.writeln('ai_test_flutter: flutter run pid=$childPid');
    stdout.writeln('ai_test_flutter: vmServiceUri=$vmServiceUri');
    stdout.writeln('ai_test_flutter: state=${StateFile.path}');
    stdout.writeln('ai_test_flutter: log=${logFile.path}');
    if (chromePid != null) {
      stdout.writeln('ai_test_flutter: chromePid=$chromePid');
    }
    if (tmpProfileDir != null) {
      stdout.writeln('ai_test_flutter: tmpProfileDir=$tmpProfileDir');
    }
  }

  /// D6 Layer 1 — pre-flight reaper.
  ///
  /// Runs `pgrep -fl flutter_tools_chrome_device` and SIGKILLs every matching
  /// PID, then walks the OS temp root and recursively removes every orphan
  /// `flutter_tools_chrome_device.<random>` directory. Wrapped in try/catch
  /// at every step — a failure to reap must NEVER block a fresh start; the
  /// worst case is the operator has to clean up manually.
  Future<void> _reapOrphans() async {
    // 1. Kill orphan Chrome processes.
    try {
      final ProcessResult result = await _processRun(
        'pgrep',
        <String>['-fl', _chromeProfileMarker],
      );
      if (result.exitCode == 0) {
        final List<int> pids = _parsePgrepFullList(result.stdout as String);
        for (final int pid in pids) {
          try {
            _killPid(pid, ProcessSignal.sigkill);
          } catch (e) {
            stderr.writeln(
              'ai_test_flutter start: reaper failed to kill pid=$pid: $e '
              '(continuing).',
            );
          }
        }
        if (pids.isNotEmpty) {
          stderr.writeln(
            'ai_test_flutter start: reaper killed ${pids.length} orphan '
            'Chrome process(es) (${pids.join(', ')}).',
          );
        }
      }
    } catch (e) {
      stderr.writeln(
        'ai_test_flutter start: reaper pgrep step failed: $e (continuing).',
      );
    }

    // 2. Walk the OS temp tree, remove orphan profile dirs.
    try {
      final List<String> tmpRoots = _tmpRoots();
      int removed = 0;
      for (final String root in tmpRoots) {
        // Per-root try/catch: a PermissionDenied on a system-owned tmp dir
        // (macOS `/var/folders/zz/.../T/`) must NOT abort the scan of the
        // other roots (the user's own `/var/folders/43/.../T/` for example).
        try {
          final Directory dir = Directory(root);
          if (!dir.existsSync()) continue;
          // Two-level walk: the OS-temp root contains `flutter_tools.<random>`
          // parent dirs, and each parent contains zero or one
          // `flutter_tools_chrome_device.<random>` subdir.
          for (final FileSystemEntity parent in dir.listSync()) {
            if (parent is! Directory) continue;
            final String parentName =
                parent.uri.pathSegments.where((String s) => s.isNotEmpty).last;
            if (!parentName.startsWith('flutter_tools.')) continue;
            // Per-parent try/catch: a permission error on one
            // `flutter_tools.X/` must not abort the scan of sibling parents.
            try {
              for (final FileSystemEntity child in parent.listSync()) {
                if (child is! Directory) continue;
                final String childName = child.uri.pathSegments
                    .where((String s) => s.isNotEmpty)
                    .last;
                if (!childName.startsWith('flutter_tools_chrome_device.')) {
                  continue;
                }
                try {
                  child.deleteSync(recursive: true);
                  removed++;
                } catch (e) {
                  stderr.writeln(
                    'ai_test_flutter start: reaper failed to remove '
                    '${child.path}: $e (continuing).',
                  );
                }
              }
            } catch (_) {
              // Permission denied on this parent — skip silently; the noise
              // is not actionable.
            }
          }
        } catch (e) {
          stderr.writeln(
            'ai_test_flutter start: reaper skipped root $root: $e '
            '(continuing).',
          );
        }
      }
      if (removed > 0) {
        stderr.writeln(
          'ai_test_flutter start: reaper removed $removed orphan '
          'flutter_tools_chrome_device directory(ies).',
        );
      }
    } catch (e) {
      stderr.writeln(
        'ai_test_flutter start: reaper tmp-dir step failed: $e (continuing).',
      );
    }
  }

  /// Returns the OS temp roots the reaper should walk.
  ///
  /// macOS `/var/folders/<X>/<Y>/T/` is enumerated by walking `/var/folders/`
  /// two levels deep; Linux uses `/tmp`. [tmpRootOverride] short-circuits both
  /// for tests.
  List<String> _tmpRoots() {
    if (tmpRootOverride != null) return <String>[tmpRootOverride!];
    if (Platform.isMacOS) {
      // Enumerate `/var/folders/*/*/T/` — that's where Flutter writes.
      // Permission errors at any level are swallowed silently; the system-
      // owned `/var/folders/zz/.../T/` typically refuses listSync and that's
      // not actionable.
      final List<String> roots = <String>[];
      final Directory base = Directory('/var/folders');
      if (!base.existsSync()) return roots;
      List<FileSystemEntity> outers;
      try {
        outers = base.listSync();
      } catch (_) {
        return roots;
      }
      for (final FileSystemEntity outer in outers) {
        if (outer is! Directory) continue;
        try {
          for (final FileSystemEntity inner in outer.listSync()) {
            if (inner is! Directory) continue;
            final Directory t = Directory('${inner.path}/T');
            if (t.existsSync()) roots.add(t.path);
          }
        } catch (_) {
          // Permission denied on this `<outer>` — skip; sibling outers may
          // still be readable.
        }
      }
      return roots;
    }
    // Linux + any other POSIX: the spec's `/tmp` is canonical.
    return <String>['/tmp'];
  }

  /// Parses `pgrep -fl` output into a list of PIDs. Each line is
  /// `<pid> <commandline>` (space-separated); we keep only the PID.
  static List<int> _parsePgrepFullList(String stdout) {
    final List<int> out = <int>[];
    for (final String line in const LineSplitter().convert(stdout)) {
      final String trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final int spaceIdx = trimmed.indexOf(' ');
      final String pidStr =
          spaceIdx < 0 ? trimmed : trimmed.substring(0, spaceIdx);
      final int? pid = int.tryParse(pidStr);
      if (pid != null) out.add(pid);
    }
    return out;
  }

  /// D6 Layer 2 — Chrome PID + tmpProfileDir capture.
  ///
  /// Waits [chromeCaptureDelay] for Flutter to fork Chrome, then enumerates
  /// `flutterPid`'s direct children via `pgrep -P` and runs
  /// `ps -p $child -o command=` on each. The first child whose command contains the marker
  /// `flutter_tools_chrome_device` is the Chrome top-level process; the
  /// `--user-data-dir=<path>` substring inside that command line is the
  /// profile dir.
  ///
  /// If `pgrep -P` finds no Chrome child (e.g. Flutter spawned Chrome
  /// detached), falls back to `pgrep -fl flutter_tools_chrome_device` and
  /// picks the most recently started match.
  ///
  /// Returns `_ChromeCapture(null, null)` on total failure — the matching
  /// `StopCommand` will degrade gracefully (log warning, kill flutter-only).
  Future<_ChromeCapture> _captureChrome(int flutterPid) async {
    await Future<void>.delayed(chromeCaptureDelay);

    // Primary path: enumerate flutterPid's direct children.
    try {
      final _ChromeCapture? primary = await _captureViaPgrepP(flutterPid);
      if (primary != null) return primary;
    } catch (e) {
      stderr.writeln(
        'ai_test_flutter start: Chrome capture (pgrep -P) failed: $e '
        '(falling back).',
      );
    }

    // Fallback: pick the newest flutter_tools_chrome_device process system-wide.
    try {
      final _ChromeCapture? fallback = await _captureViaPgrepFull();
      if (fallback != null) return fallback;
    } catch (e) {
      stderr.writeln(
        'ai_test_flutter start: Chrome capture (pgrep -fl) fallback failed: $e '
        '(GC degraded for this session).',
      );
    }

    stderr.writeln(
      'ai_test_flutter start: Chrome PID capture failed — '
      'StopCommand will be flutter-only for this session.',
    );
    return const _ChromeCapture(null, null);
  }

  /// Primary capture: `pgrep -P <flutterPid>` + `ps -p <child> -o command=`.
  Future<_ChromeCapture?> _captureViaPgrepP(int flutterPid) async {
    final ProcessResult result = await _processRun(
      'pgrep',
      <String>['-P', '$flutterPid'],
    );
    if (result.exitCode != 0) return null;

    final List<int> children = const LineSplitter()
        .convert(result.stdout as String)
        .map((String s) => int.tryParse(s.trim()))
        .whereType<int>()
        .toList();

    for (final int child in children) {
      final ProcessResult ps = await _processRun(
        'ps',
        <String>['-p', '$child', '-o', 'command='],
      );
      if (ps.exitCode != 0) continue;
      final String command = (ps.stdout as String).trim();
      if (!command.contains(_chromeProfileMarker)) continue;
      // Matched: this child is the Chrome top-level.
      final String? profileDir = _extractUserDataDir(command);
      return _ChromeCapture(child, profileDir);
    }
    return null;
  }

  /// Fallback capture: `pgrep -fl flutter_tools_chrome_device` + `ps -o lstart=`
  /// to pick the newest match. Used when Flutter detached Chrome from its
  /// process tree so `pgrep -P` returned no Chrome child.
  Future<_ChromeCapture?> _captureViaPgrepFull() async {
    final ProcessResult result = await _processRun(
      'pgrep',
      <String>['-fl', _chromeProfileMarker],
    );
    if (result.exitCode != 0) return null;

    final List<_PgrepFullEntry> entries = <_PgrepFullEntry>[];
    for (final String line
        in const LineSplitter().convert(result.stdout as String)) {
      final String trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final int spaceIdx = trimmed.indexOf(' ');
      if (spaceIdx < 0) continue;
      final int? pid = int.tryParse(trimmed.substring(0, spaceIdx));
      if (pid == null) continue;
      entries.add(_PgrepFullEntry(pid, trimmed.substring(spaceIdx + 1)));
    }
    if (entries.isEmpty) return null;

    // Pick the newest by lstart timestamp. If lstart probes fail just take
    // the highest PID (a coarse proxy for "newer process").
    _PgrepFullEntry? newest;
    DateTime? newestStart;
    for (final _PgrepFullEntry e in entries) {
      try {
        final ProcessResult ps = await _processRun(
          'ps',
          <String>['-p', '${e.pid}', '-o', 'lstart='],
        );
        if (ps.exitCode != 0) continue;
        final DateTime? lstart = _parseLstart((ps.stdout as String).trim());
        if (lstart != null &&
            (newestStart == null || lstart.isAfter(newestStart))) {
          newest = e;
          newestStart = lstart;
        }
      } catch (_) {
        // Per-entry probe failure is acceptable; keep scanning.
      }
    }
    newest ??= entries.reduce(
      (_PgrepFullEntry a, _PgrepFullEntry b) => a.pid > b.pid ? a : b,
    );

    final String? profileDir = _extractUserDataDir(newest.command);
    return _ChromeCapture(newest.pid, profileDir);
  }

  /// Extracts `<path>` from `--user-data-dir=<path>`; returns null when the
  /// argument is absent (rare — only happens when the marker matched but the
  /// argument did not, e.g. a stripped command line).
  static String? _extractUserDataDir(String command) {
    final Match? match = _userDataDirPattern.firstMatch(command);
    return match?.group(1);
  }

  /// Parses BSD `ps -o lstart=` output (`Day Mon  D HH:MM:SS YYYY`). Returns
  /// null on any format mismatch — the fallback path treats null as "unknown
  /// age" and degrades to highest-PID heuristic.
  static DateTime? _parseLstart(String lstart) {
    try {
      // Example: "Fri May 16 12:13:13 2026"
      final List<String> parts = lstart
          .split(RegExp(r'\s+'))
          .where((String s) => s.isNotEmpty)
          .toList();
      if (parts.length < 5) return null;
      const Map<String, int> months = <String, int>{
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
      final int? month = months[parts[1]];
      final int? day = int.tryParse(parts[2]);
      final List<String> time = parts[3].split(':');
      if (month == null || day == null || time.length != 3) return null;
      final int? year = int.tryParse(parts[4]);
      if (year == null) return null;
      return DateTime(
        year,
        month,
        day,
        int.parse(time[0]),
        int.parse(time[1]),
        int.parse(time[2]),
      );
    } catch (_) {
      return null;
    }
  }

  /// Reads the wrapper shell's stdout for the single `$!` line emitted after
  /// the background spawn.
  Future<int> _scrapeChildPid(Process process) async {
    final Completer<int> completer = Completer<int>();
    late final StreamSubscription<String> sub;

    sub = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((String line) {
      final String trimmed = line.trim();
      final int? pid = int.tryParse(trimmed);
      if (pid != null && !completer.isCompleted) {
        completer.complete(pid);
        sub.cancel();
      }
    }, onError: (Object e, StackTrace s) {
      if (!completer.isCompleted) completer.completeError(e, s);
    });

    try {
      return await completer.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      await sub.cancel();
      throw UsageException(
        'Timed out waiting for the wrapper shell to echo the flutter run '
        'PID. Is `nohup` available on PATH?',
        usage,
      );
    }
  }

  /// Polls [logFile] every 250 ms until a line matches [_uriPattern].
  Future<String> _scrapeVmServiceUriFromFile(File logFile) async {
    final Stopwatch elapsed = Stopwatch()..start();
    int lastSize = 0;
    while (elapsed.elapsed < uriScrapeTimeout) {
      if (logFile.existsSync()) {
        final int size = logFile.lengthSync();
        if (size > lastSize) {
          final String chunk = logFile.readAsStringSync();
          for (final String line in const LineSplitter().convert(chunk)) {
            final Match? match = _uriPattern.firstMatch(line);
            if (match != null) return match.group(1)!;
          }
          lastSize = size;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw UsageException(
      'Timed out after ${uriScrapeTimeout.inSeconds}s waiting for the VM '
      'service URI line in ${logFile.path}. Run `flutter doctor` and inspect '
      'the log directly with `ai_test_flutter logs`.',
      usage,
    );
  }

  /// Shell-quotes a list of argv tokens for safe `sh -c` interpolation.
  /// Bareword tokens (alphanumerics + `_./=:-`) pass through unquoted;
  /// anything else gets single-quoted with embedded quotes escaped.
  static String _shellQuote(List<String> tokens) {
    final RegExp bareword = RegExp(r'^[A-Za-z0-9_./=:-]+$');
    return tokens.map((String t) {
      if (bareword.hasMatch(t)) return t;
      return "'${t.replaceAll("'", r"'\''")}'";
    }).join(' ');
  }

  /// Resolves the captured-stdout log path: same parent as [StateFile.path]
  /// so `StateFile.debugHomeOverride` propagates into tests transparently.
  static String _logPath() {
    return '${File(StateFile.path).parent.path}/flutter-dev.log';
  }
}

/// Outcome of D6 Layer 2 capture. Both fields independent: capture may find
/// the PID but fail to parse the user-data-dir, or vice-versa.
class _ChromeCapture {
  const _ChromeCapture(this.pid, this.tmpProfileDir);

  final int? pid;
  final String? tmpProfileDir;
}

/// Single `pgrep -fl` row: PID + the full command line as printed by pgrep.
class _PgrepFullEntry {
  const _PgrepFullEntry(this.pid, this.command);

  final int pid;
  final String command;
}
