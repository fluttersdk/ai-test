library;

import 'dart:convert';

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart' as log;
import 'package:magic/magic.dart';

/// Tests for the `ext.aitest.network_requests` and `ext.aitest.console_messages`
/// VM Service extensions (Step 12 of V3 plan).
///
/// Runs on the VM target — no browser API needed; both extensions read from
/// the ring buffers maintained by [AiTestHttpInterceptor] and [AiTestLogSink].
///
/// Asserts:
///
/// network_requests:
/// 1. Handler returns JSON with a `requests` array containing captured entries.
/// 2. `limit` parameter caps the number of returned entries.
/// 3. `filter` parameter restricts entries by URL substring.
/// 4. Returned entries are JSON-serializable (DateTime coerced to ISO string).
///
/// console_messages:
/// 5. Handler returns JSON with a `messages` array containing captured log entries.
/// 6. `limit` parameter caps the number of returned entries.
/// 7. `level` parameter ('warning') filters out records below WARNING.
/// 8. Unknown level names fall through without error (all records returned).
/// 9. Returned entries are JSON-serializable.
///
/// registration:
/// 10. `registerNetworkConsoleExtensions()` is callable twice without throwing.
void main() {
  setUp(() {
    // Reset both ring buffers and re-register sinks so every test starts clean.
    AiTestHttpInterceptor.resetForTesting();
    AiTestLogSink.resetForTesting();

    log.Logger.root.level = log.Level.ALL;
    AiTestLogSink.register();
  });

  // ---------------------------------------------------------------------------
  // ext.aitest.network_requests
  // ---------------------------------------------------------------------------

  group('ext.aitest.network_requests handler', () {
    test('returns requests array with captured HTTP entries', () async {
      // 1. Push a sample request/response pair into the interceptor buffer.
      final interceptor = AiTestHttpInterceptor.instance;
      interceptor.onRequest(
        MagicRequest(
          url: '/monitors',
          method: 'GET',
          headers: const {},
          data: null,
          queryParameters: const {},
        ),
      );
      interceptor.onResponse(
        MagicResponse(
          data: {'data': []},
          statusCode: 200,
          headers: const {},
          message: 'OK',
        ),
      );

      // 2. Invoke the extension handler.
      final response = await aiTestNetworkRequestsHandler(
        'ext.aitest.network_requests',
        <String, String>{},
      );

      // 3. Decode and assert shape.
      final map = jsonDecode(response.result!) as Map<String, dynamic>;
      final requests = map['requests'] as List<dynamic>;
      expect(requests, hasLength(1));

      final entry = requests.first as Map<String, dynamic>;
      expect(entry['url'], equals('/monitors'));
      expect(entry['method'], equals('GET'));
      expect(entry['statusCode'], equals(200));
      expect(entry['isError'], isFalse);
    });

    test('limit param caps the returned entries', () async {
      final interceptor = AiTestHttpInterceptor.instance;
      for (var i = 1; i <= 5; i++) {
        interceptor.onRequest(
          MagicRequest(
            url: '/item/$i',
            method: 'GET',
            headers: const {},
            data: null,
            queryParameters: const {},
          ),
        );
        interceptor.onResponse(
          MagicResponse(
            data: null,
            statusCode: 200,
            headers: const {},
            message: 'OK',
          ),
        );
      }

      final response = await aiTestNetworkRequestsHandler(
        'ext.aitest.network_requests',
        <String, String>{'limit': '3'},
      );

      final map = jsonDecode(response.result!) as Map<String, dynamic>;
      final requests = map['requests'] as List<dynamic>;
      expect(requests, hasLength(3));
    });

    test('filter param restricts entries by URL substring', () async {
      final interceptor = AiTestHttpInterceptor.instance;

      // Push two different URLs.
      for (final url in ['/monitors', '/incidents']) {
        interceptor.onRequest(
          MagicRequest(
            url: url,
            method: 'GET',
            headers: const {},
            data: null,
            queryParameters: const {},
          ),
        );
        interceptor.onResponse(
          MagicResponse(
            data: null,
            statusCode: 200,
            headers: const {},
            message: 'OK',
          ),
        );
      }

      final response = await aiTestNetworkRequestsHandler(
        'ext.aitest.network_requests',
        <String, String>{'filter': 'monitors'},
      );

      final map = jsonDecode(response.result!) as Map<String, dynamic>;
      final requests = map['requests'] as List<dynamic>;
      expect(requests, hasLength(1));
      expect((requests.first as Map<String, dynamic>)['url'],
          contains('monitors'));
    });

    test('returned entries are JSON-serializable (no raw DateTime)', () async {
      final interceptor = AiTestHttpInterceptor.instance;
      interceptor.onRequest(
        MagicRequest(
          url: '/ping',
          method: 'GET',
          headers: const {},
          data: null,
          queryParameters: const {},
        ),
      );
      interceptor.onResponse(
        MagicResponse(
          data: null,
          statusCode: 204,
          headers: const {},
          message: 'No Content',
        ),
      );

      final response = await aiTestNetworkRequestsHandler(
        'ext.aitest.network_requests',
        <String, String>{},
      );

      // jsonDecode the response string without throwing.
      expect(() => jsonDecode(response.result!), returnsNormally);
    });

    test('returns empty requests array when buffer is empty', () async {
      final response = await aiTestNetworkRequestsHandler(
        'ext.aitest.network_requests',
        <String, String>{},
      );

      final map = jsonDecode(response.result!) as Map<String, dynamic>;
      final requests = map['requests'] as List<dynamic>;
      expect(requests, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // ext.aitest.console_messages
  // ---------------------------------------------------------------------------

  group('ext.aitest.console_messages handler', () {
    test('returns messages array with captured log entries', () async {
      final logger = log.Logger('test.ext');
      logger.info('monitor check started');

      final response = await aiTestConsoleMessagesHandler(
        'ext.aitest.console_messages',
        <String, String>{},
      );

      final map = jsonDecode(response.result!) as Map<String, dynamic>;
      final messages = map['messages'] as List<dynamic>;
      expect(messages, hasLength(1));

      final entry = messages.first as Map<String, dynamic>;
      expect(entry['message'], equals('monitor check started'));
      expect(entry['level'], equals('INFO'));
      expect(entry['loggerName'], equals('test.ext'));
    });

    test('limit param caps the returned entries', () async {
      final logger = log.Logger('test.limit');
      for (var i = 1; i <= 8; i++) {
        logger.info('msg $i');
      }

      final response = await aiTestConsoleMessagesHandler(
        'ext.aitest.console_messages',
        <String, String>{'limit': '5'},
      );

      final map = jsonDecode(response.result!) as Map<String, dynamic>;
      final messages = map['messages'] as List<dynamic>;
      expect(messages, hasLength(5));
    });

    test('level param "warning" filters out INFO records', () async {
      final logger = log.Logger('test.level');
      logger.fine('fine noise');
      logger.info('info noise');
      logger.warning('this matters');
      logger.severe('critical');

      final response = await aiTestConsoleMessagesHandler(
        'ext.aitest.console_messages',
        <String, String>{'level': 'warning'},
      );

      final map = jsonDecode(response.result!) as Map<String, dynamic>;
      final messages = map['messages'] as List<dynamic>;
      final levels =
          messages.map((e) => (e as Map<String, dynamic>)['level']).toList();

      expect(levels, isNot(contains('FINE')));
      expect(levels, isNot(contains('INFO')));
      expect(levels, contains('WARNING'));
      expect(levels, contains('SEVERE'));
    });

    test('level param "error" maps to SEVERE threshold', () async {
      final logger = log.Logger('test.error');
      logger.warning('skip me');
      logger.severe('keep me');

      final response = await aiTestConsoleMessagesHandler(
        'ext.aitest.console_messages',
        <String, String>{'level': 'error'},
      );

      final map = jsonDecode(response.result!) as Map<String, dynamic>;
      final messages = map['messages'] as List<dynamic>;
      final levels =
          messages.map((e) => (e as Map<String, dynamic>)['level']).toList();

      expect(levels, isNot(contains('WARNING')));
      expect(levels, contains('SEVERE'));
    });

    test('unknown level name returns all records without error', () async {
      final logger = log.Logger('test.unknown');
      logger.info('hello');

      final response = await aiTestConsoleMessagesHandler(
        'ext.aitest.console_messages',
        <String, String>{'level': 'nonsense'},
      );

      final map = jsonDecode(response.result!) as Map<String, dynamic>;
      final messages = map['messages'] as List<dynamic>;
      expect(messages, hasLength(1));
    });

    test('returned entries are JSON-serializable', () async {
      final logger = log.Logger('test.serial');
      logger.info('check serial');

      final response = await aiTestConsoleMessagesHandler(
        'ext.aitest.console_messages',
        <String, String>{},
      );

      expect(() => jsonDecode(response.result!), returnsNormally);
    });

    test('returns empty messages array when buffer is empty', () async {
      AiTestLogSink.resetForTesting();

      final response = await aiTestConsoleMessagesHandler(
        'ext.aitest.console_messages',
        <String, String>{},
      );

      final map = jsonDecode(response.result!) as Map<String, dynamic>;
      final messages = map['messages'] as List<dynamic>;
      expect(messages, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // registration
  // ---------------------------------------------------------------------------

  group('registerNetworkConsoleExtensions()', () {
    test('is callable twice without throwing', () {
      expect(registerNetworkConsoleExtensions, returnsNormally);
      expect(registerNetworkConsoleExtensions, returnsNormally);
    });
  });
}
