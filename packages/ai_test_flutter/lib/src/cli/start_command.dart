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

/// `ai_test_flutter start` — spawns `flutter run -d chrome` detached, scrapes
/// the VM service URI from stdout, and records the result to
/// `~/.ai-test/state.json` for downstream commands and the MCP server.
///
/// Flag set is the Wave 1 spike amendment (Flutter 3.41+ rejects the original
/// `--disable-service-auth-codes` and `--dart-vm-flags` from the planner's
/// description). The active set is:
///
///   flutter run -d chrome \
///     --web-port=<port> \
///     --no-dds \
///     --dart-define=AI_TEST=1
///
/// Auth code embedding lives inside the scraped URI (`ws://host:port/<token>/ws`)
/// so no launcher-level auth-disable is needed.
///
/// The process is started in [ProcessStartMode.detachedWithStdio] so the CLI
/// can return after the URI scrape while `flutter run` keeps running as a
/// detached process owned by the OS.
class StartCommand extends Command<void> {
  /// Constructs the command.
  ///
  /// [processStart] defaults to [Process.start]; tests inject a fake. The
  /// [uriScrapeTimeout] caps how long the command waits on stdout for the
  /// `Debug service listening on` line — exceeding it throws a [UsageException]
  /// so the user sees a clear error instead of a hung CLI.
  StartCommand({
    ProcessStarter? processStart,
    this.uriScrapeTimeout = const Duration(seconds: 90),
  }) : _processStart = processStart ?? Process.start {
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

  /// Max wait between process start and the URI scrape line on stdout.
  final Duration uriScrapeTimeout;

  final ProcessStarter _processStart;

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

    // 1. Prepare the log file. flutter run's stdout/stderr stream here so
    //    `ai_test_flutter logs --follow` can tail it after the CLI returns,
    //    AND so the spawn can fully detach from the CLI's stdio (no pipe
    //    keeps the parent alive). Truncated on every start.
    final File logFile = File(_logPath());
    await logFile.parent.create(recursive: true);
    await logFile.writeAsString('');

    // 2. Build the launcher argv — Wave 1 amended set only.
    final List<String> flutterArgs = <String>[
      'run',
      '-d',
      'chrome',
      '--web-port=$webPort',
      if (!ddsOn) '--no-dds',
      '--dart-define=AI_TEST=1',
    ];

    // 3. Spawn through `nohup` so the child survives the CLI's exit. On
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
              logFile.path
            ])} 2>&1 & echo \$!',
      ],
      mode: ProcessStartMode.detachedWithStdio,
    );

    // 4. The shell wrapper echoes the child PID on its (very short) stdout.
    final int childPid = await _scrapeChildPid(process);

    // 5. Tail the log file for the VM service URI (timeout-guarded). Reading
    //    from the file decouples from the wrapper process lifetime.
    final String vmServiceUri = await _scrapeVmServiceUriFromFile(logFile);

    // 6. Persist state.json atomically.
    await StateFile.write(<String, dynamic>{
      'pid': childPid,
      'vmServiceUri': vmServiceUri,
      'webPort': webPort,
      'vmServicePort': vmServicePort,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'profile': profileStatic ? 'static' : 'debug',
      'projectRoot': Directory.current.path,
    });

    stdout.writeln('ai_test_flutter: flutter run pid=$childPid');
    stdout.writeln('ai_test_flutter: vmServiceUri=$vmServiceUri');
    stdout.writeln('ai_test_flutter: state=${StateFile.path}');
    stdout.writeln('ai_test_flutter: log=${logFile.path}');
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
