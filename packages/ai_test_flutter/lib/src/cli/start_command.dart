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
        defaultsTo: true,
        negatable: true,
        help: 'Pass --no-dds when disabled (default: on, i.e. DDS off).',
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

    // 1. Build the launcher argv — Wave 1 amended set only.
    final List<String> args = <String>[
      'run',
      '-d',
      'chrome',
      '--web-port=$webPort',
      if (!ddsOn) '--no-dds' else '--no-dds',
      '--dart-define=AI_TEST=1',
    ];

    // 2. Spawn detached so the CLI can return while flutter keeps running.
    final Process process = await _processStart(
      'flutter',
      args,
      mode: ProcessStartMode.detachedWithStdio,
    );

    // 3. Scrape the VM service URI from stdout (timeout-guarded).
    final String vmServiceUri = await _scrapeVmServiceUri(process);

    // 4. Persist state.json atomically.
    await StateFile.write(<String, dynamic>{
      'pid': process.pid,
      'vmServiceUri': vmServiceUri,
      'webPort': webPort,
      'vmServicePort': vmServicePort,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'profile': profileStatic ? 'static' : 'debug',
      'projectRoot': Directory.current.path,
    });

    stdout.writeln('ai_test_flutter: flutter run pid=${process.pid}');
    stdout.writeln('ai_test_flutter: vmServiceUri=$vmServiceUri');
    stdout.writeln('ai_test_flutter: state=${StateFile.path}');
  }

  /// Listens to [process].stdout until a line matches [_uriPattern], or throws
  /// a [UsageException] after [uriScrapeTimeout].
  Future<String> _scrapeVmServiceUri(Process process) async {
    final Completer<String> completer = Completer<String>();
    late final StreamSubscription<String> sub;

    sub = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((String line) {
      final Match? match = _uriPattern.firstMatch(line);
      if (match != null && !completer.isCompleted) {
        completer.complete(match.group(1));
        sub.cancel();
      }
    }, onError: (Object e, StackTrace s) {
      if (!completer.isCompleted) {
        completer.completeError(e, s);
      }
    });

    try {
      return await completer.future.timeout(uriScrapeTimeout);
    } on TimeoutException {
      await sub.cancel();
      throw UsageException(
        'Timed out after ${uriScrapeTimeout.inSeconds}s waiting for the VM '
        'service URI line on flutter stdout. Is `flutter run -d chrome` able '
        'to launch from this directory? Run `flutter doctor` and try again.',
        usage,
      );
    }
  }
}
