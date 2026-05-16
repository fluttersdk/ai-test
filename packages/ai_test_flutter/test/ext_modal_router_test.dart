library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for `ext.aitest.dismiss_modals` VM Service extension (Step 10 of the
/// V3 production-readiness plan, D3 + D10 deliverables).
///
/// Covers:
/// 1. Single `showModalBottomSheet` — handler pops it, returns `{popped: 1}`.
/// 2. No modal on screen — handler returns `{popped: 0}` immediately.
/// 3. Pure page navigation (`MaterialPageRoute`) — handler skips it, `{popped: 0}`.
/// 4. Two stacked modals (bottom sheet on top of dialog) — pops both, `{popped: 2}`.
///
/// ## Async pattern
///
/// `aiTestDismissModalsHandler` awaits `WidgetsBinding.instance.endOfFrame`
/// after each pop. Widget tests use a fake-async binding where frames only
/// advance on explicit `tester.pump()` calls. The test therefore starts the
/// handler future, drives frames via `pumpAndSettle`, and then awaits the
/// completed future.
void main() {
  // ---------------------------------------------------------------------------
  // 1. Single modal bottom sheet — pops it, {popped: 1}
  // ---------------------------------------------------------------------------

  group('aiTestDismissModalsHandler — single modal', () {
    testWidgets('pops showModalBottomSheet and returns {popped: 1}',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              return Scaffold(
                body: ElevatedButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => const SizedBox(
                      height: 200,
                      child: Center(child: Text('Sheet content')),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              );
            },
          ),
        ),
      );

      // Open the bottom sheet.
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Verify sheet is on screen before calling the handler.
      expect(find.text('Sheet content'), findsOneWidget);

      // Start the handler — it calls endOfFrame internally after each pop.
      final Future<developer.ServiceExtensionResponse> responseFuture =
          aiTestDismissModalsHandler('ext.aitest.dismiss_modals', {});

      // Pump frames so endOfFrame completes.
      await tester.pumpAndSettle();

      final developer.ServiceExtensionResponse response = await responseFuture;

      // Sheet must be gone.
      expect(find.text('Sheet content'), findsNothing);

      // Response must carry {popped: 1}.
      final Map<String, dynamic> payload =
          jsonDecode(response.result!) as Map<String, dynamic>;
      expect(payload['popped'], equals(1));
    });
  });

  // ---------------------------------------------------------------------------
  // 2. No modal — returns {popped: 0}
  // ---------------------------------------------------------------------------

  group('aiTestDismissModalsHandler — no modal', () {
    testWidgets('returns {popped: 0} when no modal is open',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Page')),
        ),
      );

      final developer.ServiceExtensionResponse response =
          await aiTestDismissModalsHandler('ext.aitest.dismiss_modals', {});

      final Map<String, dynamic> payload =
          jsonDecode(response.result!) as Map<String, dynamic>;
      expect(payload['popped'], equals(0));
    });
  });

  // ---------------------------------------------------------------------------
  // 3. MaterialPageRoute navigation — handler must NOT pop it
  // ---------------------------------------------------------------------------

  group('aiTestDismissModalsHandler — page route', () {
    testWidgets(
        'skips MaterialPageRoute from Navigator.push, returns {popped: 0}',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              return Scaffold(
                body: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(body: Text('Second page')),
                    ),
                  ),
                  child: const Text('Go'),
                ),
              );
            },
          ),
        ),
      );

      // Navigate to a second page via MaterialPageRoute.
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();

      expect(find.text('Second page'), findsOneWidget);

      // Dismiss handler should NOT pop a MaterialPageRoute.
      final developer.ServiceExtensionResponse response =
          await aiTestDismissModalsHandler('ext.aitest.dismiss_modals', {});

      // Second page must still be visible.
      expect(find.text('Second page'), findsOneWidget);

      final Map<String, dynamic> payload =
          jsonDecode(response.result!) as Map<String, dynamic>;
      expect(payload['popped'], equals(0));
    });
  });

  // ---------------------------------------------------------------------------
  // 4. Two stacked modals — pops both, {popped: 2}
  // ---------------------------------------------------------------------------

  group('aiTestDismissModalsHandler — two stacked modals', () {
    testWidgets(
        'pops bottom sheet stacked on top of dialog, returns {popped: 2}',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              return Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    // Open a dialog first.
                    unawaited(
                      showDialog<void>(
                        context: context,
                        builder: (_) =>
                            const AlertDialog(content: Text('Dialog')),
                      ),
                    );
                    await Future<void>.delayed(Duration.zero);

                    // Then open a bottom sheet on top.
                    if (context.mounted) {
                      unawaited(
                        showModalBottomSheet<void>(
                          context: context,
                          builder: (_) => const SizedBox(
                            height: 200,
                            child: Text('Sheet on top'),
                          ),
                        ),
                      );
                    }
                  },
                  child: const Text('Stack'),
                ),
              );
            },
          ),
        ),
      );

      // Open both modals.
      await tester.tap(find.text('Stack'));
      await tester.pumpAndSettle();

      // Both should be visible.
      expect(find.text('Sheet on top'), findsOneWidget);
      expect(find.text('Dialog'), findsOneWidget);

      // Start handler.
      final Future<developer.ServiceExtensionResponse> responseFuture =
          aiTestDismissModalsHandler('ext.aitest.dismiss_modals', {});

      // Drive frames so each endOfFrame awaited by the handler completes.
      await tester.pumpAndSettle();

      final developer.ServiceExtensionResponse response = await responseFuture;

      // Both modals must be gone.
      expect(find.text('Sheet on top'), findsNothing);
      expect(find.text('Dialog'), findsNothing);

      final Map<String, dynamic> payload =
          jsonDecode(response.result!) as Map<String, dynamic>;
      expect(payload['popped'], equals(2));
    });
  });

  // ---------------------------------------------------------------------------
  // 5. Registration is idempotent
  // ---------------------------------------------------------------------------

  group('registerModalRouterExtension', () {
    test('registers without throwing (idempotent on double-call)', () {
      expect(registerModalRouterExtension, returnsNormally);
      expect(registerModalRouterExtension, returnsNormally);
    });
  });
}
