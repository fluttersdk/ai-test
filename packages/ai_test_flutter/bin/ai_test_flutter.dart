import 'dart:io';

import 'package:args/command_runner.dart';

import 'package:ai_test_flutter/src/cli/doctor_command.dart';
import 'package:ai_test_flutter/src/cli/logs_command.dart';
import 'package:ai_test_flutter/src/cli/restart_command.dart';
import 'package:ai_test_flutter/src/cli/start_command.dart';
import 'package:ai_test_flutter/src/cli/status_command.dart';
import 'package:ai_test_flutter/src/cli/stop_command.dart';

/// Entry point for the `ai_test_flutter` CLI.
///
/// Usage: `dart run ai_test_flutter:ai_test_flutter <command>` (development)
/// or `ai_test_flutter <command>` after `dart pub global activate`.
///
/// Wave 4 ships only `start`; Wave 4 Step 16 adds `stop`, `status`, `doctor`,
/// `logs`, `restart`. Each command lives in its own `lib/src/cli/<verb>_command.dart`
/// module and is registered here.
Future<void> main(List<String> args) async {
  final CommandRunner<void> runner = CommandRunner<void>(
    'ai_test_flutter',
    'Flutter web LLM-agent test plugin lifecycle (V3 — MCP-only single-channel).',
  )
    ..addCommand(StartCommand())
    ..addCommand(StopCommand())
    ..addCommand(StatusCommand())
    ..addCommand(DoctorCommand())
    ..addCommand(LogsCommand())
    ..addCommand(RestartCommand());

  try {
    await runner.run(args);
  } on UsageException catch (e) {
    // 1. UsageException is the args-package signal for malformed CLI input.
    //    Print the formatted help message and exit with shell convention 64
    //    (EX_USAGE).
    stderr.writeln(e);
    exit(64);
  }
}
