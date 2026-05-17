import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

/// `flutter_console_messages` regression guard.
///
/// Emits records to `package:logging`'s root logger so [AiTestLogSink]
/// (which subscribes to `Logger.root.onRecord`) captures them. Tapping
/// each button emits one record at the named level. The integration test
/// calls `aiTestConsoleMessagesHandler` and asserts the buffer contains
/// the expected messages.
class LogEmitScenario extends StatelessWidget {
  const LogEmitScenario({super.key});

  static final Logger _log = Logger('ai_test.fixture.log_emit');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Log emit (console_messages)')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ElevatedButton(
              onPressed: () => _log.info('fixture info ping'),
              child: const Text('Emit INFO'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => _log.warning('fixture warning ping'),
              child: const Text('Emit WARNING'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => _log.severe('fixture severe ping'),
              child: const Text('Emit SEVERE'),
            ),
          ],
        ),
      ),
    );
  }
}
