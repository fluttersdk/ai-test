library;

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Direct src imports bypass the barrel (ai_test_flutter.dart), which
// transitively exports ext_wait_find.dart — a Step 14 file with compile
// errors while that parallel step is in-progress. Using direct relative
// imports lets this Step 7 test file compile and run independently. The
// avoid_relative_lib_imports lint fires at `info` severity (not `warning`
// or `error`) and does not block the build.
import '../lib/src/ext_pointer.dart';
import '../lib/src/ref_registry.dart';

/// Tests for the `ext.aitest.tap`, `ext.aitest.hover`, and `ext.aitest.drag`
/// VM Service extensions (Step 7 of V3 plan).
///
/// Each test pumps a real widget tree, registers a ref via [RefRegistry]
/// directly, drives the extension handler, and asserts the expected callback
/// fired.
///
/// ## Async pattern
///
/// Extension handlers call `WidgetsBinding.instance.endOfFrame` internally,
/// which in widget tests only completes after `tester.pump()`. The pattern:
///
/// ```dart
/// final future = aiTestTapHandler(...);  // start — do not await yet
/// await tester.pump(Duration(milliseconds: 50)); // advance fake timer
/// await tester.pump();                           // first endOfFrame
/// await tester.pump();                           // second endOfFrame
/// final response = await future;                 // collect result
/// ```
///
/// Sizing: use 1440×900 to avoid layout instability on the default 800×600.
void main() {
  setUp(() {
    // Reset the registry between tests so ref IDs and entries do not bleed
    // across test cases.
    RefRegistry.resetForTesting();
  });

  // ---------------------------------------------------------------------------
  // ext.aitest.tap — GestureDetector.onTap fires
  // ---------------------------------------------------------------------------

  group('ext.aitest.tap', () {
    testWidgets('fires GestureDetector.onTap when ref resolves to widget rect',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      var tapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: GestureDetector(
                onTap: () => tapped = true,
                child: const SizedBox(
                  width: 100,
                  height: 50,
                  child: ColoredBox(color: Colors.blue),
                ),
              ),
            ),
          ),
        ),
      );

      // 1. Locate the GestureDetector element and its bounding rect.
      final element = tester.element(find.byType(GestureDetector));
      final box = element.findRenderObject()! as RenderBox;
      final topLeft = box.localToGlobal(Offset.zero);
      final rect = topLeft & box.size;

      // 2. Register a ref for this element so the handler can resolve it.
      final ref = RefRegistry.registerForTesting(
        rect: rect,
        element: element,
        groupId: 'test-tap',
        isTextField: false,
      );

      // 3. Start handler (do NOT await — it will call endOfFrame internally,
      //    which only resolves after tester.pump()).
      final future = aiTestTapHandler(
        'ext.aitest.tap',
        <String, String>{'ref': ref},
      );

      // 4. Advance the fake timer by 50ms (covers the Down→Up delay) and pump
      //    two frames to resolve both endOfFrame awaits in the handler.
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();

      final response = await future;

      // 5. The tap should have reached the GestureDetector.
      expect(tapped, isTrue, reason: 'GestureDetector.onTap must fire');

      // 6. Handler response carries the ref it acted on.
      final body = jsonDecode(response.result!) as Map<String, dynamic>;
      expect(body['ref'], equals(ref));
    });

    testWidgets('returns error response when ref is not found',
        (WidgetTester tester) async {
      final response = await aiTestTapHandler(
        'ext.aitest.tap',
        const <String, String>{'ref': 'e999'},
      );

      expect(
        response.errorCode,
        equals(developer.ServiceExtensionResponse.extensionError),
        reason: 'Missing ref must return extensionError',
      );
    });

    testWidgets('calls requestKeyboard() when ref is a text-field',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final focusNode = FocusNode();
      final controller = TextEditingController();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                ),
              ),
            ),
          ),
        ),
      );

      // 1. Locate the TextField's EditableText element — the handler walks
      //    descendants of the registered element to find EditableTextState.
      final element = tester.element(find.byType(TextField));
      final box = element.findRenderObject()! as RenderBox;
      final topLeft = box.localToGlobal(Offset.zero);
      final rect = topLeft & box.size;

      // 2. Register the ref as a text-field so the handler triggers
      //    requestKeyboard() after the pointer events.
      final ref = RefRegistry.registerForTesting(
        rect: rect,
        element: element,
        groupId: 'test-tap-tf',
        isTextField: true,
      );

      // 3. Start handler and advance timers / frames.
      final future = aiTestTapHandler(
        'ext.aitest.tap',
        <String, String>{'ref': ref},
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();

      await future;

      // 4. Verify the field has primary focus (requestKeyboard succeeded).
      expect(
        focusNode.hasPrimaryFocus,
        isTrue,
        reason: 'requestKeyboard() must grant primary focus to the TextField',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // ext.aitest.hover — MouseRegion.onEnter fires
  // ---------------------------------------------------------------------------

  group('ext.aitest.hover', () {
    testWidgets('emits PointerHoverEvent with mouse kind and returns ref',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      // MouseRegion.onEnter requires the MouseTracker to process the hover
      // event. In widget tests the tracker runs after a pump(). We collect
      // onEnter via a flag and pump after the handler future starts.
      var entered = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MouseRegion(
                key: const ValueKey('hover-target'),
                onEnter: (_) => entered = true,
                child: const SizedBox(
                  width: 100,
                  height: 50,
                  child: ColoredBox(color: Colors.green),
                ),
              ),
            ),
          ),
        ),
      );

      // 1. Locate our specific MouseRegion element (MaterialApp adds its own
      //    MouseRegions internally; use the key to disambiguate).
      final element = tester.element(
        find.byKey(const ValueKey('hover-target')),
      );
      final box = element.findRenderObject()! as RenderBox;
      final topLeft = box.localToGlobal(Offset.zero);
      final rect = topLeft & box.size;

      // 2. Register the ref.
      final ref = RefRegistry.registerForTesting(
        rect: rect,
        element: element,
        groupId: 'test-hover',
        isTextField: false,
      );

      // 3. Start handler and pump two frames to resolve endOfFrame awaits and
      //    let the MouseTracker flush the hover event.
      final future = aiTestHoverHandler(
        'ext.aitest.hover',
        <String, String>{'ref': ref},
      );
      await tester.pump();
      await tester.pump();

      final response = await future;

      // 4. The MouseRegion.onEnter callback must fire.
      expect(entered, isTrue, reason: 'MouseRegion.onEnter must fire on hover');

      // 5. Response carries the ref.
      final body = jsonDecode(response.result!) as Map<String, dynamic>;
      expect(body['ref'], equals(ref));
    });

    testWidgets('returns error response when ref is not found',
        (WidgetTester tester) async {
      final response = await aiTestHoverHandler(
        'ext.aitest.hover',
        const <String, String>{'ref': 'e998'},
      );

      expect(
        response.errorCode,
        equals(developer.ServiceExtensionResponse.extensionError),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // ext.aitest.drag — pointer gesture dispatches Down+Move+Up
  // ---------------------------------------------------------------------------

  group('ext.aitest.drag', () {
    testWidgets(
        'dispatches Down+Move+Up sequence; GestureDetector.onPanEnd fires',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      // Use a GestureDetector with onPanEnd rather than Draggable; the
      // Draggable's DragTarget drop mechanism involves an overlay lookup that
      // is unreliable in headless widget tests. onPanEnd fires when the Down
      // + Move + Up sequence is complete — sufficient to verify pointer
      // dispatch reached the registered rect.
      var panEnded = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 100,
                  top: 100,
                  child: GestureDetector(
                    onPanEnd: (_) => panEnded = true,
                    child: const SizedBox(
                      width: 80,
                      height: 80,
                      key: ValueKey('drag-source'),
                      child: ColoredBox(color: Colors.orange),
                    ),
                  ),
                ),
                const Positioned(
                  left: 600,
                  top: 100,
                  child: SizedBox(
                    width: 80,
                    height: 80,
                    key: ValueKey('drag-target'),
                    child: ColoredBox(color: Colors.yellow),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      // 1. Locate source and register as startRef.
      final sourceElement = tester.element(
        find.byKey(const ValueKey('drag-source')),
      );
      final sourceBox = sourceElement.findRenderObject()! as RenderBox;
      final sourceRect = sourceBox.localToGlobal(Offset.zero) & sourceBox.size;

      final startRef = RefRegistry.registerForTesting(
        rect: sourceRect,
        element: sourceElement,
        groupId: 'test-drag',
        isTextField: false,
      );

      // 2. Locate target and register as endRef.
      final targetElement = tester.element(
        find.byKey(const ValueKey('drag-target')),
      );
      final targetBox = targetElement.findRenderObject()! as RenderBox;
      final targetRect = targetBox.localToGlobal(Offset.zero) & targetBox.size;

      final endRef = RefRegistry.registerForTesting(
        rect: targetRect,
        element: targetElement,
        groupId: 'test-drag',
        isTextField: false,
      );

      // 3. Start the drag handler. It will await multiple Future.delayed(16ms)
      //    calls — one per Move step. We pump 16ms per step + final frames.
      final future = aiTestDragHandler(
        'ext.aitest.drag',
        <String, String>{
          'startRef': startRef,
          'endRef': endRef,
        },
      );

      // 4. Advance 5 × 16ms steps (each Move event) + 16ms for the Up, then
      //    two extra frames to settle gesture callbacks and endOfFrame awaits.
      for (var i = 0; i <= 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump();
      await tester.pump();

      final response = await future;

      // 5. Gesture callbacks must have fired and response carries both refs.
      expect(panEnded, isTrue, reason: 'GestureDetector.onPanEnd must fire');
      final body = jsonDecode(response.result!) as Map<String, dynamic>;
      expect(body['startRef'], equals(startRef));
      expect(body['endRef'], equals(endRef));
    });

    test('returns error when startRef is missing from registry', () async {
      // The handler checks startRef first. No widget tree needed — the error
      // fires before any endRef lookup or pointer dispatch.
      final response = await aiTestDragHandler(
        'ext.aitest.drag',
        const <String, String>{
          'startRef': 'e999',
          'endRef': 'e998',
        },
      );

      expect(
        response.errorCode,
        equals(developer.ServiceExtensionResponse.extensionError),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // registerPointerExtensions — self-registration
  // ---------------------------------------------------------------------------

  group('registerPointerExtensions', () {
    test('registers all 3 extensions without throwing', () {
      expect(registerPointerExtensions, returnsNormally);
    });

    test('can be called twice (idempotent via registerExtensionIdempotent)',
        () {
      registerPointerExtensions();
      // Second call must NOT throw even though extensions are already registered.
      expect(registerPointerExtensions, returnsNormally);
    });
  });
}
