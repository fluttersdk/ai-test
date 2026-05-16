library;

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:magic/magic.dart';

/// Tests for the `ext.aitest.mock_http` VM Service extension (Step 13 of V3 plan).
///
/// Covers:
/// 1. [AiTestHttpInterceptor.addMockRule] stores rules that [onRequest]
///    matches by URL substring before passing to the network.
/// 2. [AiTestHttpInterceptor.addMockRule] stores rules matched by regex pattern.
/// 3. [AiTestHttpInterceptor.onRequest] returns a synthesized [MagicResponse]
///    when a rule matches — short-circuiting the network.
/// 4. [AiTestHttpInterceptor.onRequest] returns the original [MagicRequest]
///    when no rule matches — letting the request proceed normally.
/// 5. [AiTestHttpInterceptor.clearMockRules] removes all registered rules.
/// 6. Later-registered rules take priority over earlier ones (LIFO match order).
/// 7. [aiTestMockHttpHandler] encodes the rule into the interceptor via the
///    VM extension params map.
/// 8. [registerMockHttpExtension] is idempotent — calling it twice does not
///    throw (ArgumentError swallowed via [registerExtensionIdempotent]).
void main() {
  setUp(() {
    AiTestHttpInterceptor.resetForTesting();
  });

  // ---------------------------------------------------------------------------
  // addMockRule + onRequest — substring match
  // ---------------------------------------------------------------------------

  group('AiTestHttpInterceptor.addMockRule — substring match', () {
    test(
        'onRequest returns synthesized MagicResponse when URL contains pattern',
        () {
      AiTestHttpInterceptor.addMockRule({
        'pattern': '/monitors',
        'status': 200,
        'body': '{"data":[]}',
      });

      final request = MagicRequest(
        url: '/monitors',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      );

      final result = AiTestHttpInterceptor.instance.onRequest(request);

      expect(
        result,
        isA<MagicResponse>(),
        reason: 'Matched request must short-circuit with MagicResponse',
      );

      final response = result as MagicResponse;
      expect(response.statusCode, equals(200));
      expect(response.data, equals('{"data":[]}'));
    });

    test('onRequest returns original MagicRequest when no rule matches', () {
      AiTestHttpInterceptor.addMockRule({
        'pattern': '/incidents',
        'status': 200,
        'body': '{"data":[]}',
      });

      final request = MagicRequest(
        url: '/monitors',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      );

      final result = AiTestHttpInterceptor.instance.onRequest(request);

      expect(
        result,
        isA<MagicRequest>(),
        reason: 'Unmatched request must proceed as MagicRequest',
      );
    });

    test('onRequest returns original MagicRequest when rules list is empty',
        () {
      final request = MagicRequest(
        url: '/monitors',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      );

      final result = AiTestHttpInterceptor.instance.onRequest(request);

      expect(result, isA<MagicRequest>());
    });
  });

  // ---------------------------------------------------------------------------
  // addMockRule — regex match
  // ---------------------------------------------------------------------------

  group('AiTestHttpInterceptor.addMockRule — regex match', () {
    test('onRequest matches URL via regex pattern (r"/monitors/\\d+")', () {
      AiTestHttpInterceptor.addMockRule({
        'pattern': r'/monitors/\d+',
        'status': 404,
        'body': '{"message":"not found"}',
      });

      final request = MagicRequest(
        url: '/monitors/42',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      );

      final result = AiTestHttpInterceptor.instance.onRequest(request);

      expect(result, isA<MagicResponse>());
      final response = result as MagicResponse;
      expect(response.statusCode, equals(404));
    });

    test('regex pattern does not match unrelated URL', () {
      AiTestHttpInterceptor.addMockRule({
        'pattern': r'/monitors/\d+',
        'status': 200,
        'body': '{}',
      });

      final request = MagicRequest(
        url: '/incidents',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      );

      final result = AiTestHttpInterceptor.instance.onRequest(request);
      expect(result, isA<MagicRequest>());
    });
  });

  // ---------------------------------------------------------------------------
  // Response headers + contentType
  // ---------------------------------------------------------------------------

  group('AiTestHttpInterceptor.addMockRule — headers and contentType', () {
    test('synthesized response carries custom status code', () {
      AiTestHttpInterceptor.addMockRule({
        'pattern': '/health',
        'status': 503,
        'body': 'Service Unavailable',
        'contentType': 'text/plain',
      });

      final request = MagicRequest(
        url: '/health',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      );

      final result = AiTestHttpInterceptor.instance.onRequest(request);
      expect(result, isA<MagicResponse>());
      final response = result as MagicResponse;
      expect(response.statusCode, equals(503));
    });

    test('synthesized response includes extra headers when rule provides them',
        () {
      AiTestHttpInterceptor.addMockRule({
        'pattern': '/auth/token',
        'status': 200,
        'body': '{"token":"abc123"}',
        'headers': {'x-custom-header': 'test-value'},
      });

      final request = MagicRequest(
        url: '/auth/token',
        method: 'POST',
        headers: const {},
        data: null,
        queryParameters: const {},
      );

      final result = AiTestHttpInterceptor.instance.onRequest(request);
      expect(result, isA<MagicResponse>());
      final response = result as MagicResponse;
      expect(response.headers['x-custom-header'], equals('test-value'));
    });
  });

  // ---------------------------------------------------------------------------
  // LIFO match order — later rule wins
  // ---------------------------------------------------------------------------

  group('AiTestHttpInterceptor.addMockRule — LIFO priority', () {
    test('later-added rule takes priority over earlier rule for the same URL',
        () {
      AiTestHttpInterceptor.addMockRule({
        'pattern': '/monitors',
        'status': 200,
        'body': 'first',
      });
      AiTestHttpInterceptor.addMockRule({
        'pattern': '/monitors',
        'status': 201,
        'body': 'second',
      });

      final request = MagicRequest(
        url: '/monitors',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      );

      final result = AiTestHttpInterceptor.instance.onRequest(request);
      expect(result, isA<MagicResponse>());
      final response = result as MagicResponse;
      // Later rule (status 201 / 'second') wins.
      expect(response.statusCode, equals(201));
      expect(response.data, equals('second'));
    });
  });

  // ---------------------------------------------------------------------------
  // clearMockRules
  // ---------------------------------------------------------------------------

  group('AiTestHttpInterceptor.clearMockRules', () {
    test('clears all registered rules so subsequent requests pass through', () {
      AiTestHttpInterceptor.addMockRule({
        'pattern': '/monitors',
        'status': 200,
        'body': '{}',
      });

      AiTestHttpInterceptor.clearMockRules();

      final request = MagicRequest(
        url: '/monitors',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      );

      final result = AiTestHttpInterceptor.instance.onRequest(request);
      expect(
        result,
        isA<MagicRequest>(),
        reason: 'Rules must be cleared — request should pass through',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // aiTestMockHttpHandler — VM Service extension round-trip
  // ---------------------------------------------------------------------------

  group('aiTestMockHttpHandler (ServiceExtension round-trip)', () {
    test('handler registers a mock rule and returns ok:true', () async {
      final response = await aiTestMockHttpHandler(
        'ext.aitest.mock_http',
        <String, String>{
          'pattern': '/ping',
          'status': '204',
          'body': '',
        },
      );

      final body = jsonDecode(response.result!) as Map<String, dynamic>;
      expect(body['ok'], isTrue);
      expect(body['pattern'], equals('/ping'));

      // Rule must now be active — subsequent onRequest for /ping is mocked.
      final request = MagicRequest(
        url: '/ping',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      );
      final result = AiTestHttpInterceptor.instance.onRequest(request);
      expect(result, isA<MagicResponse>());
      final mr = result as MagicResponse;
      expect(mr.statusCode, equals(204));
    });

    test('handler returns extensionError when required params are missing',
        () async {
      final response = await aiTestMockHttpHandler(
        'ext.aitest.mock_http',
        // Missing 'pattern' and 'status'.
        <String, String>{'body': '{}'},
      );

      expect(
        response.errorCode,
        equals(developer.ServiceExtensionResponse.extensionError),
        reason: 'Missing required params must return extensionError',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // registerMockHttpExtension — self-registration idempotency
  // ---------------------------------------------------------------------------

  group('registerMockHttpExtension()', () {
    test('is idempotent — calling twice does not throw', () {
      expect(registerMockHttpExtension, returnsNormally);
      expect(registerMockHttpExtension, returnsNormally);
    });
  });
}
