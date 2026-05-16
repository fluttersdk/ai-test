library;

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:ai_test_flutter_example/main.dart' as app;
import 'package:ai_test_flutter_example/scenarios/checkbox_row.dart';
import 'package:ai_test_flutter_example/scenarios/modal_sheet.dart';
import 'package:ai_test_flutter_example/scenarios/network_form.dart';
import 'package:ai_test_flutter_example/scenarios/wbutton_nested.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:magic/magic.dart';

/// Integration tests for the V3 ai_test_flutter plugin against the fixture
/// example app.
///
/// Each test boots the fixture app at the relevant route and verifies BOTH:
/// 1. Direct widget interaction works (baseline — proves the scenario widget
///    is wired correctly and the fix being guarded is observable end-to-end).
/// 2. The plugin's `ext.aitest.*` handlers, invoked in-process, return the
///    expected envelopes for the scenario state.
///
/// Test 1 (wbutton_nested) → D2 hit-test regression guard.
/// Test 2 (checkbox_row)   → D2 + DEFECT-6 regression guard.
/// Test 3 (modal_sheet)    → D3 + D10 modal handling regression guard.
/// Test 4 (network_form)   → D9 wait_for_request regression guard.
///
/// ## Why we don't drive `aiTestTapHandler` here
///
/// `aiTestTapHandler` internally calls
/// `WidgetsBinding.instance.handlePointerEvent` plus a real-clock
/// `Future.delayed(50ms)`. Under [IntegrationTestWidgetsFlutterBinding] (a
/// live binding) the interleaving of `runAsync` + pumping makes the pointer
/// dispatch unreliable — the same handler is unit-tested in
/// `test/ext_pointer_test.dart` against the deterministic
/// [TestWidgetsFlutterBinding] (fake-async) which is the right environment
/// for that. Here we verify the SAME end-to-end outcome (counter increment,
/// selection toggle) via `tester.tap`, which exercises the gesture binding
/// through the binding's blessed test API.
///
/// ## Handlers we DO drive here
///
/// * `aiTestDismissModalsHandler` — synchronous Navigator.pop loop; no real
///   clock dependency, safe under the live binding.
/// * `aiTestWaitForRequestHandler` — pre-match path is synchronous (scans the
///   already-populated ring buffer); we exercise that path so the D9 contract
///   is observable from the fixture.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Reset registry + interceptor buffer between tests so state does not
    // bleed across scenarios.
    RefRegistry.resetForTesting();
    AiTestHttpInterceptor.resetForTesting();
  });

  // ---------------------------------------------------------------------------
  // Scenario 1: nested WButton-shape — D2 hit-test reaches ancestor recognizer
  // ---------------------------------------------------------------------------

  testWidgets('D2: tap on inner Text inside InkWell increments counter', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester
        .pumpWidget(const app.AiTestExampleApp(initialRoute: '/wbutton'));
    await tester.pumpAndSettle();

    expect(find.text('Taps: 0'), findsOneWidget);

    // Tap on the inner Text — D2 regression case: the inner Text/Icon has no
    // recognizer; only the ancestor InkWell does. Pre-D2 the snapshot ref
    // would land on the inner widget and a tap dispatched at its center could
    // miss the ancestor recognizer. Post-D2 the gesture binding's hit-test
    // sweeps the recognizer chain regardless of which descendant the ref
    // points at.
    await tester.tap(find.text(WButtonNestedScenario.label));
    await tester.pumpAndSettle();

    expect(find.text('Taps: 1'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // Scenario 2: checkbox row (DEFECT-6) — ancestor InkWell wraps icon + label
  // ---------------------------------------------------------------------------

  testWidgets('DEFECT-6: tap on row toggles selection state', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester
        .pumpWidget(const app.AiTestExampleApp(initialRoute: '/checkbox'));
    await tester.pumpAndSettle();

    expect(find.text('Selected: 0'), findsOneWidget);

    // Tap on the label text — same shape as MonitorAssignList row.
    await tester.tap(find.text(CheckboxRowScenario.label));
    await tester.pumpAndSettle();

    expect(find.text('Selected: 1'), findsOneWidget);

    // Tap again to toggle off — verifies the recognizer is reachable on
    // every cycle, not just the first.
    await tester.tap(find.text(CheckboxRowScenario.label));
    await tester.pumpAndSettle();

    expect(find.text('Selected: 0'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // Scenario 3: modal bottom sheet — D3 auto-dismiss + D10 dismiss_modals
  // ---------------------------------------------------------------------------

  testWidgets('D10: aiTestDismissModalsHandler pops a modal bottom sheet', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const app.AiTestExampleApp(initialRoute: '/modal'));
    await tester.pump(const Duration(milliseconds: 200));

    // 1. Sheet closed initially.
    expect(find.text('Sheet: closed'), findsOneWidget);

    // 2. Open the sheet. Use explicit pump (not pumpAndSettle) — the modal
    //    barrier scrim animation may not declare itself "settled" under the
    //    live binding; the default sheet animation lands in ~250ms.
    await tester.tap(find.text(ModalSheetScenario.openLabel));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Sheet: open'), findsOneWidget);
    expect(find.text(ModalSheetScenario.sheetTitle), findsOneWidget);

    // 3. Dismiss via the handler envelope so the D10 contract is exercised
    //    end-to-end (not just the internal dismissAllModals helper). The
    //    handler awaits `WidgetsBinding.instance.endOfFrame` between pops;
    //    under the live binding endOfFrame only completes when a frame is
    //    scheduled, so we pump alongside the handler future until it
    //    resolves. Race-safe: the future settles within ~250ms (the bottom
    //    sheet dismissal animation).
    final pending = aiTestDismissModalsHandler(
      'ext.aitest.dismiss_modals',
      const <String, String>{},
    );
    developer.ServiceExtensionResponse? response;
    pending.then((r) => response = r);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (response == null && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(response, isNotNull, reason: 'dismiss_modals handler must resolve');
    await tester.pump(const Duration(milliseconds: 500));

    // 4. Envelope reports one popped route; sheet closed.
    final body = jsonDecode(response!.result!) as Map<String, dynamic>;
    expect(body['popped'], equals(1));
    expect(find.text('Sheet: closed'), findsOneWidget);
    expect(find.text(ModalSheetScenario.sheetTitle), findsNothing);
  });

  testWidgets('D10: dismissAllModals returns 0 when no modal is open', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const app.AiTestExampleApp(initialRoute: '/modal'));
    await tester.pump(const Duration(milliseconds: 200));

    final popped = await dismissAllModals();
    expect(popped, equals(0));
  });

  // ---------------------------------------------------------------------------
  // Scenario 4: network form — D9 wait_for_request observes ring buffer
  // ---------------------------------------------------------------------------

  testWidgets('D9: network form tap increments response counter', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    // Inject a mock fetcher so the test does not hit the real network. The
    // stub feeds the AiTestHttpInterceptor's public Magic-typed surface so
    // the ring buffer reflects the round-trip the D9 handler will scan.
    await tester.pumpWidget(
      app.AiTestExampleApp(
        initialRoute: '/network',
        networkFetcher: _mockFetcher,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Responses: 0'), findsOneWidget);

    await tester.tap(find.text(NetworkFormScenario.submitLabel));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Responses: 1'), findsOneWidget);
  });

  testWidgets('D9: aiTestWaitForRequestHandler matches buffered entry', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      app.AiTestExampleApp(
        initialRoute: '/network',
        networkFetcher: _mockFetcher,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // 1. Fire the request via the scenario UI so an entry lands in the
    //    interceptor's ring buffer BEFORE the handler runs. This exercises
    //    the D9 handler's pre-match path (synchronous scan of the buffer),
    //    which avoids the live-binding stream-subscription timer issues
    //    surfaced in earlier iterations.
    await tester.tap(find.text(NetworkFormScenario.submitLabel));
    await tester.pump(const Duration(milliseconds: 200));

    // 2. The pre-match path must return matched=true immediately for the
    //    already-buffered entry. timeoutMs is large but unused on this path.
    final response = await aiTestWaitForRequestHandler(
      'ext.aitest.wait_for_request',
      <String, String>{
        'urlPattern': r'jsonplaceholder\.typicode\.com/posts',
        'method': 'POST',
        'timeoutMs': '2000',
      },
    );

    final body = jsonDecode(response.result!) as Map<String, dynamic>;
    expect(body['matched'], isTrue);
    expect(body['method'], equals('POST'));
    expect(body['statusCode'], equals(201));
  });
}

/// Mock fetcher shared by the network-form tests.
///
/// Feeds the interceptor's public Magic-typed surface so the ring buffer
/// reflects what the production interceptor would record without bootstrapping
/// the magic network stack (which would require `Magic.init`).
Future<int> _mockFetcher(Uri url, Object? body) async {
  AiTestHttpInterceptor.instance.onRequest(
    MagicRequest(
      url: url.toString(),
      method: 'POST',
      headers: const <String, dynamic>{},
      data: body,
    ),
  );
  AiTestHttpInterceptor.instance.onResponse(
    MagicResponse(
      data: '{"id": 101}',
      statusCode: 201,
      headers: const <String, dynamic>{},
    ),
  );
  return 201;
}
