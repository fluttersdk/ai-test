library;

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:magic/magic.dart';

/// Tests for [AiTestHttpInterceptor] (Step 5 of V3 plan).
///
/// Runs on the VM target — no browser API needed; the interceptor is a
/// pure ring-buffer data structure that does not depend on `kIsWeb`.
///
/// Asserts:
/// 1. `register()` is idempotent — calling it twice does not throw.
/// 2. Captured requests appear in `recentRequests()`.
/// 3. Ring buffer evicts the oldest entry when the 51st request is added
///    (max capacity is 50).
/// 4. `recentRequests(limit: N)` returns at most N entries.
void main() {
  setUp(() {
    // Reset the interceptor ring buffer between tests so each test starts
    // from an empty slate (the singleton's buffer persists across tests
    // otherwise, which would break count-based assertions).
    AiTestHttpInterceptor.resetForTesting();
  });

  group('AiTestHttpInterceptor', () {
    test('register() is idempotent — calling twice does not throw', () {
      expect(AiTestHttpInterceptor.register, returnsNormally);
      expect(AiTestHttpInterceptor.register, returnsNormally);
    });

    test('onResponse() captures request + response into the ring buffer', () {
      final interceptor = AiTestHttpInterceptor.instance;

      final request = MagicRequest(
        url: '/monitors',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      );

      final response = MagicResponse(
        data: {'data': []},
        statusCode: 200,
        headers: const {},
        message: 'OK',
      );

      // Simulate the interceptor lifecycle: request in, response out.
      interceptor.onRequest(request);
      interceptor.onResponse(response);

      final recent = AiTestHttpInterceptor.recentRequests();
      expect(recent, hasLength(1));
      expect(recent.first['method'], equals('GET'));
      expect(recent.first['url'], equals('/monitors'));
      expect(recent.first['statusCode'], equals(200));
    });

    test(
      'ring buffer evicts oldest entry at 51st insert (max capacity 50)',
      () {
        final interceptor = AiTestHttpInterceptor.instance;

        // 1. Push 50 requests to fill the buffer to capacity.
        for (var i = 1; i <= 50; i++) {
          final request = MagicRequest(
            url: '/item/$i',
            method: 'GET',
            headers: const {},
            data: null,
            queryParameters: const {},
          );
          final response = MagicResponse(
            data: null,
            statusCode: 200,
            headers: const {},
            message: 'OK',
          );
          interceptor.onRequest(request);
          interceptor.onResponse(response);
        }

        expect(AiTestHttpInterceptor.recentRequests(), hasLength(50));

        // 2. Add the 51st entry — the oldest (/item/1) must be evicted.
        final request51 = MagicRequest(
          url: '/item/51',
          method: 'GET',
          headers: const {},
          data: null,
          queryParameters: const {},
        );
        final response51 = MagicResponse(
          data: null,
          statusCode: 201,
          headers: const {},
          message: 'Created',
        );
        interceptor.onRequest(request51);
        interceptor.onResponse(response51);

        final all = AiTestHttpInterceptor.recentRequests();

        // 3. Buffer is still 50 entries, not 51.
        expect(all, hasLength(50));

        // 4. Oldest entry (/item/1) is gone.
        final urls = all.map((e) => e['url'] as String).toList();
        expect(urls, isNot(contains('/item/1')));

        // 5. Newest entry is present.
        expect(urls, contains('/item/51'));
      },
    );

    test('recentRequests(limit: N) returns at most N entries', () {
      final interceptor = AiTestHttpInterceptor.instance;

      for (var i = 1; i <= 10; i++) {
        final request = MagicRequest(
          url: '/r/$i',
          method: 'POST',
          headers: const {},
          data: null,
          queryParameters: const {},
        );
        final response = MagicResponse(
          data: null,
          statusCode: 201,
          headers: const {},
          message: 'Created',
        );
        interceptor.onRequest(request);
        interceptor.onResponse(response);
      }

      final limited = AiTestHttpInterceptor.recentRequests(limit: 3);
      expect(limited, hasLength(3));
    });

    test('recentRequests() returns immutable copies — mutations do not leak',
        () {
      final interceptor = AiTestHttpInterceptor.instance;

      final request = MagicRequest(
        url: '/ping',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      );
      final response = MagicResponse(
        data: null,
        statusCode: 200,
        headers: const {},
        message: 'OK',
      );
      interceptor.onRequest(request);
      interceptor.onResponse(response);

      final first = AiTestHttpInterceptor.recentRequests();
      first.add({'url': 'injected', 'method': 'HACK', 'statusCode': 0});

      // Internal buffer must not have grown.
      expect(AiTestHttpInterceptor.recentRequests(), hasLength(1));
    });
  });
}
