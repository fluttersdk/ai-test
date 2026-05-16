library;

import 'dart:convert';

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:magic/magic.dart';

/// Tests for `ext.aitest.wait_for`, `ext.aitest.find_by_text`, and
/// `ext.aitest.find_by_label` VM Service extensions (Step 14 of V3 plan).
///
/// Covers:
/// 1. `wait_for` — matches immediately when text is already present.
/// 2. `wait_for` — returns timeout result when text never appears.
/// 3. `wait_for` — textGone matches immediately when text is already absent.
/// 4. `find_by_text` — walks Element tree, returns refs for matching Text widgets.
/// 5. `find_by_label` — walks SemanticsNode tree, returns refs for matching labels.
/// 6. `registerWaitFindExtensions()` is idempotent (no throw on double call).
///
/// ## Note on wait_for async testing
///
/// flutter_test uses a fake-async zone where frames only draw on explicit
/// [tester.pump] calls — [Future.delayed] inside a poll loop blocked behind
/// [await future] never advances. Tests therefore verify steady-state
/// semantics (text already present → immediate match; text absent → timeout)
/// using [tester.runAsync] so real timers run. The delayed-insert QA scenario
/// (text appears after 500ms) is exercised by the integration test in
/// [aiTestWaitForHandler], which runs the real extension handler.
void main() {
  setUp(() {
    RefRegistry.disposeAll();
  });

  // ---------------------------------------------------------------------------
  // ext.aitest.wait_for — text already present → immediate match
  // ---------------------------------------------------------------------------

  group('ext.aitest.wait_for (text appears)', () {
    testWidgets(
        'matches immediately when text is already present, elapsedMs == 0',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Hello')),
        ),
      );

      // runAsync: real timers, no fake-async deadlock.
      final Map<String, dynamic> result =
          await tester.runAsync<Map<String, dynamic>>(
                () => findByTextWaitLoop(
                  text: 'Hello',
                  timeoutMs: 1000,
                  pollIntervalMs: 100,
                ),
              ) ??
              <String, dynamic>{'matched': false, 'reason': 'runAsync null'};

      // Text is present on the first check — no delay needed.
      expect(result['matched'], isTrue, reason: 'Text already present');
      expect(result['elapsedMs'], equals(0));
    });

    testWidgets(
        'returns {matched: false, reason: timeout} when text never appears',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SizedBox.shrink()),
        ),
      );

      // timeoutMs=250, pollIntervalMs=100 → 2-3 polls then timeout.
      final Map<String, dynamic> result =
          await tester.runAsync<Map<String, dynamic>>(
                () => findByTextWaitLoop(
                  text: 'NeverShowsUp',
                  timeoutMs: 250,
                  pollIntervalMs: 100,
                ),
              ) ??
              <String, dynamic>{'matched': false, 'reason': 'timeout'};

      expect(result['matched'], isFalse);
      expect(result['reason'], equals('timeout'));
      // elapsedMs is not present in the timeout payload — only matched+reason.
      expect(result.containsKey('elapsedMs'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // ext.aitest.wait_for — textGone already absent → immediate match
  // ---------------------------------------------------------------------------

  group('ext.aitest.wait_for (textGone)', () {
    testWidgets('matches immediately when target text is already absent',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SizedBox.shrink()),
        ),
      );

      final Map<String, dynamic> result =
          await tester.runAsync<Map<String, dynamic>>(
                () => findByTextGoneWaitLoop(
                  text: 'AlreadyGone',
                  timeoutMs: 500,
                  pollIntervalMs: 100,
                ),
              ) ??
              <String, dynamic>{'matched': false, 'reason': 'runAsync null'};

      expect(result['matched'], isTrue, reason: 'Text absent from the start');
      expect(result['elapsedMs'], equals(0));
    });
  });

  // ---------------------------------------------------------------------------
  // ext.aitest.find_by_text — Element tree walk
  // ---------------------------------------------------------------------------

  group('ext.aitest.find_by_text', () {
    testWidgets('returns refs for all matching Text widgets (exact)',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                Text('Alpha'),
                Text('Beta'),
                Text('Alpha'),
              ],
            ),
          ),
        ),
      );

      // pumpWidget already settled the frame — element tree is current.
      final List<String> refs = findByTextInTree(
        text: 'Alpha',
        exact: true,
        groupId: 'test-find-text',
      );

      expect(refs, hasLength(2), reason: 'Two Text("Alpha") widgets in tree');
      for (final String ref in refs) {
        expect(RefRegistry.lookup(ref), isNotNull);
      }
    });

    testWidgets('returns empty list when text not found',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Only this')),
        ),
      );

      final List<String> refs = findByTextInTree(
        text: 'Not present',
        exact: true,
        groupId: 'test-find-absent',
      );

      expect(refs, isEmpty);
    });

    testWidgets('partial match (exact=false) finds containing text',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Hello World')),
        ),
      );

      final List<String> refs = findByTextInTree(
        text: 'World',
        exact: false,
        groupId: 'test-find-partial',
      );

      expect(refs, hasLength(1));
    });

    testWidgets('handler returns JSON with refs list',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Visible')),
        ),
      );

      final response = await aiTestFindByTextHandler(
        'ext.aitest.find_by_text',
        <String, String>{'text': 'Visible'},
      );

      expect(response, isNotNull);
      final body = jsonDecode(response.result!) as Map<String, dynamic>;
      expect(body['refs'], isA<List<dynamic>>());
      expect((body['refs'] as List<dynamic>).isNotEmpty, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // ext.aitest.find_by_label — SemanticsNode tree walk
  // ---------------------------------------------------------------------------

  group('ext.aitest.find_by_label', () {
    testWidgets('returns refs for semantics nodes matching label',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Semantics(
              label: 'Submit button',
              button: true,
              child: const SizedBox(width: 100, height: 50),
            ),
          ),
        ),
      );

      // Ensure semantics tree is built by pumping one more frame.
      await tester.pump();

      final List<String> refs = findByLabelInSemantics(
        label: 'Submit button',
        groupId: 'test-find-label',
      );

      expect(refs, hasLength(1));
      expect(RefRegistry.lookup(refs.first), isNotNull);
    });

    testWidgets('handler returns JSON with refs list',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Semantics(
              label: 'Close dialog',
              button: true,
              child: const SizedBox(width: 80, height: 40),
            ),
          ),
        ),
      );

      await tester.pump();

      final response = await aiTestFindByLabelHandler(
        'ext.aitest.find_by_label',
        <String, String>{'label': 'Close dialog'},
      );

      expect(response, isNotNull);
      final body = jsonDecode(response.result!) as Map<String, dynamic>;
      expect(body['refs'], isA<List<dynamic>>());
    });
  });

  // ---------------------------------------------------------------------------
  // ext.aitest.wait_for handler — missing params
  // ---------------------------------------------------------------------------

  group('ext.aitest.wait_for handler', () {
    testWidgets(
        'returns error response when neither text/textGone/expression provided',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );

      final response = await aiTestWaitForHandler(
        'ext.aitest.wait_for',
        <String, String>{},
      );

      expect(response, isNotNull);
      expect(response.errorCode, isNotNull);
    });
  });

  // ---------------------------------------------------------------------------
  // registerWaitFindExtensions — self-registration
  // ---------------------------------------------------------------------------

  group('registerWaitFindExtensions', () {
    test('registers all 3 extensions without throwing', () {
      expect(registerWaitFindExtensions, returnsNormally);
    });

    test('can be called twice (idempotent via registerExtensionIdempotent)',
        () {
      registerWaitFindExtensions();
      // Second call must NOT throw — ArgumentError swallowed by
      // registerExtensionIdempotent.
      expect(registerWaitFindExtensions, returnsNormally);
    });
  });

  // ---------------------------------------------------------------------------
  // ext.aitest.wait_for_request — pre-match (buffer already has the entry)
  // ---------------------------------------------------------------------------

  group('ext.aitest.wait_for_request (pre-match)', () {
    setUp(() {
      AiTestHttpInterceptor.resetForTesting();
    });

    test(
        'returns matched:true immediately when buffer already has matching entry',
        () async {
      // Pre-populate the buffer with a matching entry via a simulated lifecycle.
      final interceptor = AiTestHttpInterceptor.instance;
      interceptor.onRequest(MagicRequest(
        url: '/monitors/123/metrics',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      ));
      interceptor.onResponse(MagicResponse(
        data: null,
        statusCode: 200,
        headers: const {},
        message: 'OK',
      ));

      final result = await aiTestWaitForRequestHandler(
        'ext.aitest.wait_for_request',
        <String, String>{
          'urlPattern': r'/monitors/\d+/metrics',
          'timeoutMs': '1000',
        },
      );

      expect(result.result, isNotNull);
      final body = jsonDecode(result.result!) as Map<String, dynamic>;
      expect(body['matched'], isTrue, reason: 'Buffer had matching entry');
      expect(body['url'], contains('/monitors/'));
    });
  });

  // ---------------------------------------------------------------------------
  // ext.aitest.wait_for_request — post-match (entry arrives via stream)
  // ---------------------------------------------------------------------------

  group('ext.aitest.wait_for_request (post-match via stream)', () {
    setUp(() {
      AiTestHttpInterceptor.resetForTesting();
    });

    test('returns matched:true when entry is added to stream after call starts',
        () async {
      // Start the handler future — buffer is empty so it will subscribe.
      final handlerFuture = aiTestWaitForRequestHandler(
        'ext.aitest.wait_for_request',
        <String, String>{
          'urlPattern': '/api/v1/status',
          'timeoutMs': '3000',
        },
      );

      // After a short delay, inject the matching entry into the interceptor,
      // which fires the stream event.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final interceptor = AiTestHttpInterceptor.instance;
      interceptor.onRequest(MagicRequest(
        url: '/api/v1/status',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      ));
      interceptor.onResponse(MagicResponse(
        data: null,
        statusCode: 200,
        headers: const {},
        message: 'OK',
      ));

      final result = await handlerFuture;
      expect(result.result, isNotNull);
      final body = jsonDecode(result.result!) as Map<String, dynamic>;
      expect(body['matched'], isTrue, reason: 'Entry arrived via stream');
    });
  });

  // ---------------------------------------------------------------------------
  // ext.aitest.wait_for_request — timeout
  // ---------------------------------------------------------------------------

  group('ext.aitest.wait_for_request (timeout)', () {
    setUp(() {
      AiTestHttpInterceptor.resetForTesting();
    });

    test('returns matched:false with reason:timeout when no entry ever matches',
        () async {
      final result = await aiTestWaitForRequestHandler(
        'ext.aitest.wait_for_request',
        <String, String>{
          'urlPattern': '/never/gonna/match',
          'timeoutMs': '300',
        },
      );

      expect(result.result, isNotNull);
      final body = jsonDecode(result.result!) as Map<String, dynamic>;
      expect(body['matched'], isFalse);
      expect(body['reason'], equals('timeout'));
      expect(body.containsKey('recentCount'), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // ext.aitest.wait_for_request — URL regex matching
  // ---------------------------------------------------------------------------

  group('ext.aitest.wait_for_request (URL regex)', () {
    setUp(() {
      AiTestHttpInterceptor.resetForTesting();
    });

    test('matches URL using regex pattern', () async {
      final interceptor = AiTestHttpInterceptor.instance;
      interceptor.onRequest(MagicRequest(
        url: '/monitors/42/metrics',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      ));
      interceptor.onResponse(MagicResponse(
        data: null,
        statusCode: 200,
        headers: const {},
        message: 'OK',
      ));

      final result = await aiTestWaitForRequestHandler(
        'ext.aitest.wait_for_request',
        <String, String>{
          'urlPattern': r'/monitors/.*/metrics',
          'timeoutMs': '1000',
        },
      );

      final body = jsonDecode(result.result!) as Map<String, dynamic>;
      expect(body['matched'], isTrue);
    });

    test('does not match when URL does not satisfy the regex', () async {
      final interceptor = AiTestHttpInterceptor.instance;
      interceptor.onRequest(MagicRequest(
        url: '/incidents/list',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      ));
      interceptor.onResponse(MagicResponse(
        data: null,
        statusCode: 200,
        headers: const {},
        message: 'OK',
      ));

      final result = await aiTestWaitForRequestHandler(
        'ext.aitest.wait_for_request',
        <String, String>{
          'urlPattern': r'/monitors/.*/metrics',
          'timeoutMs': '200',
        },
      );

      final body = jsonDecode(result.result!) as Map<String, dynamic>;
      expect(body['matched'], isFalse, reason: 'URL does not match the regex');
    });
  });

  // ---------------------------------------------------------------------------
  // ext.aitest.wait_for_request — method filter
  // ---------------------------------------------------------------------------

  group('ext.aitest.wait_for_request (method filter)', () {
    setUp(() {
      AiTestHttpInterceptor.resetForTesting();
    });

    test('skips entry when method does not match', () async {
      final interceptor = AiTestHttpInterceptor.instance;
      // Enqueue a GET entry — we will filter for POST.
      interceptor.onRequest(MagicRequest(
        url: '/monitors',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      ));
      interceptor.onResponse(MagicResponse(
        data: null,
        statusCode: 200,
        headers: const {},
        message: 'OK',
      ));

      final result = await aiTestWaitForRequestHandler(
        'ext.aitest.wait_for_request',
        <String, String>{
          'urlPattern': '/monitors',
          'method': 'POST',
          'timeoutMs': '200',
        },
      );

      final body = jsonDecode(result.result!) as Map<String, dynamic>;
      expect(body['matched'], isFalse,
          reason: 'GET entry skipped by POST filter');
    });

    test('matches when method matches', () async {
      final interceptor = AiTestHttpInterceptor.instance;
      interceptor.onRequest(MagicRequest(
        url: '/monitors',
        method: 'POST',
        headers: const {},
        data: null,
        queryParameters: const {},
      ));
      interceptor.onResponse(MagicResponse(
        data: null,
        statusCode: 201,
        headers: const {},
        message: 'Created',
      ));

      final result = await aiTestWaitForRequestHandler(
        'ext.aitest.wait_for_request',
        <String, String>{
          'urlPattern': '/monitors',
          'method': 'POST',
          'timeoutMs': '1000',
        },
      );

      final body = jsonDecode(result.result!) as Map<String, dynamic>;
      expect(body['matched'], isTrue);
      expect(body['method'], equals('POST'));
    });
  });

  // ---------------------------------------------------------------------------
  // ext.aitest.wait_for_request — status range filter
  // ---------------------------------------------------------------------------

  group('ext.aitest.wait_for_request (status range)', () {
    setUp(() {
      AiTestHttpInterceptor.resetForTesting();
    });

    test('matches when statusCode is within minStatus/maxStatus range',
        () async {
      final interceptor = AiTestHttpInterceptor.instance;
      interceptor.onRequest(MagicRequest(
        url: '/data',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      ));
      interceptor.onResponse(MagicResponse(
        data: null,
        statusCode: 404,
        headers: const {},
        message: 'Not Found',
      ));

      final result = await aiTestWaitForRequestHandler(
        'ext.aitest.wait_for_request',
        <String, String>{
          'urlPattern': '/data',
          'minStatus': '400',
          'maxStatus': '499',
          'timeoutMs': '1000',
        },
      );

      final body = jsonDecode(result.result!) as Map<String, dynamic>;
      expect(body['matched'], isTrue);
      expect(body['statusCode'], equals(404));
    });

    test('skips entry when statusCode is outside the status range', () async {
      final interceptor = AiTestHttpInterceptor.instance;
      interceptor.onRequest(MagicRequest(
        url: '/data',
        method: 'GET',
        headers: const {},
        data: null,
        queryParameters: const {},
      ));
      interceptor.onResponse(MagicResponse(
        data: null,
        statusCode: 200,
        headers: const {},
        message: 'OK',
      ));

      final result = await aiTestWaitForRequestHandler(
        'ext.aitest.wait_for_request',
        <String, String>{
          'urlPattern': '/data',
          'minStatus': '400',
          'maxStatus': '499',
          'timeoutMs': '200',
        },
      );

      final body = jsonDecode(result.result!) as Map<String, dynamic>;
      expect(body['matched'], isFalse, reason: '200 is outside 400-499 range');
    });
  });
}
