library;

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

/// Tests for [AiTestLogSink] (Step 5 of V3 plan).
///
/// Runs on the VM target — no browser API needed; the log sink is a pure
/// ring-buffer subscriber for `package:logging`'s `Logger.root.onRecord`.
///
/// Asserts:
/// 1. `register()` is idempotent — calling it twice does not throw and does
///    not create duplicate subscriptions.
/// 2. Log records captured via `Logger.root` appear in `recentLogs()`.
/// 3. Ring buffer evicts the oldest entry when the 101st record is added
///    (max capacity is 100).
/// 4. `recentLogs(limit: N)` returns at most N entries.
/// 5. `recentLogs(minLevel: N)` filters records below the given level value.
void main() {
  setUp(() {
    // 1. Ensure Logger.root captures all levels so our sink receives them.
    Logger.root.level = Level.ALL;

    // 2. Reset the sink ring buffer + subscription state between tests.
    AiTestLogSink.resetForTesting();

    // 3. Re-register after reset so subsequent log() calls are captured.
    AiTestLogSink.register();
  });

  group('AiTestLogSink', () {
    test('register() is idempotent — calling twice does not throw', () {
      // register() is already called in setUp; calling again must be a no-op.
      expect(AiTestLogSink.register, returnsNormally);
      expect(AiTestLogSink.register, returnsNormally);
    });

    test('register() does not create duplicate subscriptions', () {
      // Reset + register three times.
      AiTestLogSink.resetForTesting();
      AiTestLogSink.register();
      AiTestLogSink.register();
      AiTestLogSink.register();

      final logger = Logger('test.dedup');
      logger.info('hello');

      // Only one entry must appear despite three register calls.
      expect(AiTestLogSink.recentLogs(), hasLength(1));
    });

    test('captures Logger.root records in recentLogs()', () {
      final logger = Logger('ai.test');
      logger.info('request started');

      final logs = AiTestLogSink.recentLogs();
      expect(logs, hasLength(1));
      expect(logs.first['message'], equals('request started'));
      expect(logs.first['loggerName'], equals('ai.test'));
      expect(logs.first['level'], equals('INFO'));
    });

    test(
      'ring buffer evicts oldest entry at 101st insert (max capacity 100)',
      () {
        final logger = Logger('evict.test');

        // 1. Push 100 records to fill the buffer to capacity.
        for (var i = 1; i <= 100; i++) {
          logger.info('msg $i');
        }

        expect(AiTestLogSink.recentLogs(), hasLength(100));

        // 2. Add the 101st record — the oldest ('msg 1') must be evicted.
        logger.info('msg 101');

        final all = AiTestLogSink.recentLogs();

        // 3. Buffer is still 100 entries.
        expect(all, hasLength(100));

        // 4. Oldest entry ('msg 1') is gone.
        final messages = all.map((e) => e['message'] as String).toList();
        expect(messages, isNot(contains('msg 1')));

        // 5. Newest entry is present.
        expect(messages, contains('msg 101'));
      },
    );

    test('recentLogs(limit: N) returns at most N entries', () {
      final logger = Logger('limit.test');
      for (var i = 1; i <= 10; i++) {
        logger.info('item $i');
      }

      final limited = AiTestLogSink.recentLogs(limit: 4);
      expect(limited, hasLength(4));
    });

    test('recentLogs(minLevel: N) filters records below the threshold', () {
      final logger = Logger('filter.test');
      logger.fine('fine message'); // Level.FINE  = 500
      logger.info('info message'); // Level.INFO  = 800
      logger.warning('warn message'); // Level.WARNING = 900

      // minLevel: 800 (Level.INFO.value) should exclude FINE (500).
      final filtered = AiTestLogSink.recentLogs(minLevel: Level.INFO.value);
      final messages = filtered.map((e) => e['message'] as String).toList();

      expect(messages, isNot(contains('fine message')));
      expect(messages, contains('info message'));
      expect(messages, contains('warn message'));
    });

    test('recentLogs() returns immutable copies — mutations do not leak', () {
      final logger = Logger('immutable.test');
      logger.info('check immutability');

      final first = AiTestLogSink.recentLogs();
      first.add({'level': 'INJECTED', 'message': 'hacked', 'loggerName': 'x'});

      // Internal buffer must not have grown.
      expect(AiTestLogSink.recentLogs(), hasLength(1));
    });

    test('error and stackTrace are captured when present', () {
      final logger = Logger('error.test');
      final error = Exception('boom');
      final stack = StackTrace.current;
      logger.severe('something failed', error, stack);

      final logs = AiTestLogSink.recentLogs();
      expect(logs, hasLength(1));
      expect(logs.first['error'], isNotNull);
      expect(logs.first['stackTrace'], isNotNull);
    });
  });
}
