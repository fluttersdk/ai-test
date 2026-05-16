import 'package:args/command_runner.dart';

import 'start_command.dart';
import 'stop_command.dart';

/// `ai_test_flutter restart` — convenience wrapper that runs `stop` then
/// `start` against the same process state.
///
/// Composes [StopCommand] + [StartCommand] sequentially. Tests can inject a
/// custom pair via the constructor for full mock control; production
/// invocation defaults to the real implementations.
class RestartCommand extends Command<void> {
  /// Constructs the command.
  RestartCommand({StopCommand? stop, StartCommand? start})
      : _stop = stop ?? StopCommand(),
        _start = start ?? StartCommand();

  final StopCommand _stop;
  final StartCommand _start;

  @override
  final String name = 'restart';

  @override
  final String description =
      'Stop the running `flutter run` process (if any) and start a fresh '
      'instance against the same configuration.';

  @override
  Future<void> run() async {
    await _stop.run();
    await _start.run();
  }
}
