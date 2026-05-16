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
  // D2 — gesture-binding hit-test reaches ancestor handlers
  // ---------------------------------------------------------------------------
  //
  // The DEFECT-6 root cause: snapshot refs frequently anchor on a semantic
  // leaf (a Text label, an Icon) while the actual tap handler sits on a
  // GestureDetector / InkWell / Material button ancestor. The V0/V1 fallback
  // (`_invokeTapCallback`) climbed the widget tree to invoke `onTap` /
  // `onPressed` directly because we suspected `_injectTap` would miss the
  // ancestor. These tests prove the suspicion was wrong: Flutter's gesture
  // binding hit-tests via the RENDER tree, finds the ancestor
  // RenderSemanticsGestureHandler regardless of which descendant element the
  // ref points at, and fires the recognizer. The fallback is unnecessary.

  group('ext.aitest.tap — D2 hit-test ancestor reach', () {
    testWidgets('reaches ancestor GestureDetector when ref is a leaf child',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      var counter = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: GestureDetector(
                onTap: () => counter++,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.check, key: ValueKey('leaf-icon')),
                    SizedBox(width: 8),
                    Text('X', key: ValueKey('leaf-text')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      // 1. Register the LEAF Text element (not the GestureDetector). Its rect
      //    sits inside the GestureDetector's hit region, so gesture-binding
      //    hit-test must still route the Down/Up pair to the ancestor.
      final leafElement =
          tester.element(find.byKey(const ValueKey('leaf-text')));
      final leafBox = leafElement.findRenderObject()! as RenderBox;
      final leafRect = leafBox.localToGlobal(Offset.zero) & leafBox.size;

      final ref = RefRegistry.registerForTesting(
        rect: leafRect,
        element: leafElement,
        groupId: 'test-d2-nested',
        isTextField: false,
      );

      // 2. Drive the handler.
      final future = aiTestTapHandler(
        'ext.aitest.tap',
        <String, String>{'ref': ref},
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
      final response = await future;

      // 3. The GestureDetector ancestor MUST have received the tap exactly
      //    once via gesture binding (no fallback, no double-fire).
      expect(counter, equals(1),
          reason:
              'gesture binding must route the leaf-rect tap to the ancestor '
              'GestureDetector exactly once (no fallback double-fire)');
      expect(response.errorCode, isNull);
      final body = jsonDecode(response.result!) as Map<String, dynamic>;
      expect(body['ref'], equals(ref));
    });

    testWidgets('returns OK on widgets without an onTap handler',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: ListTile(
                  key: ValueKey('inert-tile'),
                  title: Text('Just a label'),
                ),
              ),
            ),
          ),
        ),
      );

      // 1. Register the ListTile element. There is no onTap; tapping should
      //    be a silent no-op (handler returns OK, no exception, no side
      //    effects). This guards against false positives from any future
      //    fallback regression.
      final element = tester.element(find.byKey(const ValueKey('inert-tile')));
      final box = element.findRenderObject()! as RenderBox;
      final rect = box.localToGlobal(Offset.zero) & box.size;

      final ref = RefRegistry.registerForTesting(
        rect: rect,
        element: element,
        groupId: 'test-d2-inert',
        isTextField: false,
      );

      final future = aiTestTapHandler(
        'ext.aitest.tap',
        <String, String>{'ref': ref},
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
      final response = await future;

      // 2. Handler succeeded — no exception, OK envelope, ref echoed back.
      expect(response.errorCode, isNull,
          reason: 'inert widgets must not produce an error envelope');
      final body = jsonDecode(response.result!) as Map<String, dynamic>;
      expect(body['ref'], equals(ref));
    });

    testWidgets('reaches MaterialButton onPressed via gesture binding',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      var counter = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => counter++,
                child: const Text('Press me', key: ValueKey('btn-label')),
              ),
            ),
          ),
        ),
      );

      // 1. Register the BUTTON LABEL leaf (not the button itself) — the
      //    canonical DEFECT-6 shape where the semantic node points at the
      //    text inside a button.
      final labelElement =
          tester.element(find.byKey(const ValueKey('btn-label')));
      final labelBox = labelElement.findRenderObject()! as RenderBox;
      final labelRect = labelBox.localToGlobal(Offset.zero) & labelBox.size;

      final ref = RefRegistry.registerForTesting(
        rect: labelRect,
        element: labelElement,
        groupId: 'test-d2-elevated',
        isTextField: false,
      );

      final future = aiTestTapHandler(
        'ext.aitest.tap',
        <String, String>{'ref': ref},
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
      final response = await future;

      // 2. onPressed must fire exactly once — gesture binding routes the
      //    pointer events through InkResponse / Material splash to the
      //    button's TapGestureRecognizer.
      expect(counter, equals(1),
          reason: 'gesture binding must route the label-rect tap to the '
              'ElevatedButton.onPressed exactly once');
      expect(response.errorCode, isNull);
      final body = jsonDecode(response.result!) as Map<String, dynamic>;
      expect(body['ref'], equals(ref));
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

  // ---------------------------------------------------------------------------
  // D1 — tap envelope early-return + swallow post-dispatch noise
  //
  // DEFECT-1: tapping a navigation-triggering button returned a Server error
  // envelope to MCP even though the route actually changed, because any
  // exception raised AFTER `_injectTap` dispatched (e.g., accessing a
  // deactivated element during the post-dispatch keyboard-focus step) was
  // caught by the outer try/catch and converted to `.error`.
  //
  // After the D1 fix, the outer try/catch only covers PRE-dispatch code
  // (ref validation + `_injectTap` call). Post-dispatch code runs in its own
  // inner try/catch that logs but returns `.result` even when it throws.
  // ---------------------------------------------------------------------------

  group('ext.aitest.tap — D1 envelope early-return', () {
    testWidgets(
        'returns OK envelope when tap triggers navigation (DEFECT-1 regression)',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      // 1. Build a two-route app. The home page has a GestureDetector that
      //    navigates to '/elsewhere' on tap. Navigation unmounts the current
      //    page's element tree mid-dispatch and may trigger post-dispatch
      //    rebuild noise that the outer try/catch could incorrectly surface
      //    as `.error` (DEFECT-1).
      var navigated = false;
      await tester.pumpWidget(
        MaterialApp(
          initialRoute: '/',
          routes: <String, WidgetBuilder>{
            '/': (_) => Scaffold(
                  body: Center(
                    child: Builder(
                      builder: (BuildContext ctx) => GestureDetector(
                        key: const ValueKey('nav-btn'),
                        onTap: () {
                          navigated = true;
                          Navigator.of(ctx).pushNamed('/elsewhere');
                        },
                        child: const SizedBox(
                          width: 200,
                          height: 60,
                          child: ColoredBox(color: Colors.blue),
                        ),
                      ),
                    ),
                  ),
                ),
            '/elsewhere': (_) => const Scaffold(
                  body: Center(child: Text('Elsewhere')),
                ),
          },
        ),
      );

      // 2. Register the navigation button's ref.
      final navElement = tester.element(find.byKey(const ValueKey('nav-btn')));
      final navBox = navElement.findRenderObject()! as RenderBox;
      final navRect = navBox.localToGlobal(Offset.zero) & navBox.size;
      final navRef = RefRegistry.registerForTesting(
        rect: navRect,
        element: navElement,
        groupId: 'test-d1-nav',
        isTextField: false,
      );

      // 3. Start handler without awaiting — it calls endOfFrame internally,
      //    which only resolves after tester.pump().
      final future = aiTestTapHandler(
        'ext.aitest.tap',
        <String, String>{'ref': navRef},
      );

      // 4. Advance 50ms (Down→Up delay) then pump frames to resolve
      //    _injectTap's two endOfFrame awaits and the navigation animation.
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();

      final response = await future;

      // 5. Navigation must have been triggered AND the handler must return
      //    .result — not .error. This is the DEFECT-1 invariant: pointer
      //    dispatch success must not be shadowed by post-dispatch noise.
      expect(navigated, isTrue, reason: 'onTap navigation callback must fire');
      expect(
        response.errorCode,
        isNull,
        reason: 'Tap on a navigation button must return .result (OK), not '
            '.error, even though the element tree changed after dispatch.',
      );
      final body = jsonDecode(response.result!) as Map<String, dynamic>;
      expect(body['ref'], equals(navRef));
    });

    testWidgets(
        'returns OK when isTextField=true element unmounts post-dispatch',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final controller = TextEditingController();
      addTearDown(controller.dispose);

      // 1. Build an app with a text field that navigates away when tapped
      //    (simulating a "search bar → results page" flow). The text-field
      //    ref is registered; after the tap fires navigation, the field is
      //    unmounted — requestKeyboard() must be swallowed, not propagated.
      await tester.pumpWidget(
        MaterialApp(
          initialRoute: '/',
          routes: <String, WidgetBuilder>{
            '/': (_) => Scaffold(
                  body: Column(
                    children: <Widget>[
                      Builder(
                        builder: (BuildContext ctx) => GestureDetector(
                          onTap: () =>
                              Navigator.of(ctx).pushNamed('/elsewhere'),
                          child: AbsorbPointer(
                            child: TextField(
                              key: const ValueKey('search-field'),
                              controller: controller,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            '/elsewhere': (_) => const Scaffold(
                  body: Center(child: Text('Results')),
                ),
          },
        ),
      );

      // 2. Register the text-field ref with isTextField=true.
      final element =
          tester.element(find.byKey(const ValueKey('search-field')));
      final box = element.findRenderObject()! as RenderBox;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      final ref = RefRegistry.registerForTesting(
        rect: rect,
        element: element,
        groupId: 'test-d1-tf-nav',
        isTextField: true,
      );

      // 3. Drive the handler: tap fires navigation; post-dispatch keyboard
      //    focus step runs on a now-unmounted element. Must still return OK.
      final future = aiTestTapHandler(
        'ext.aitest.tap',
        <String, String>{'ref': ref},
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      final response = await future;

      // 4. Response must be .result even though requestKeyboard() may have
      //    failed on the unmounted element. Post-dispatch noise is swallowed.
      expect(
        response.errorCode,
        isNull,
        reason: 'Post-dispatch requestKeyboard failure on unmounted element '
            'must be swallowed; handler must return .result.',
      );
      final body = jsonDecode(response.result!) as Map<String, dynamic>;
      expect(body['ref'], equals(ref));
    });

    test('returns .error when ref param is empty (hard pre-dispatch error)',
        () async {
      // Hard pre-dispatch gate: empty ref must never return .result.
      final response = await aiTestTapHandler(
        'ext.aitest.tap',
        const <String, String>{'ref': ''},
      );
      expect(
        response.errorCode,
        equals(developer.ServiceExtensionResponse.extensionError),
        reason: 'Empty ref is a hard pre-dispatch error; must return .error.',
      );
    });

    test(
        'returns .error when ref is stale (removed from registry after snapshot)',
        () async {
      // Simulate the "snapshot → navigate → tap old ref" pattern.
      // The ref is registered under a group, then that group is disposed
      // (as happens when flutter_snapshot runs on a new route and disposes
      // the old snapshot's group).
      final staleRef = RefRegistry.register(
        rect: const Rect.fromLTWH(0, 0, 100, 50),
        element: WidgetsBinding.instance.rootElement!,
        groupId: 'stale-group',
        isTextField: false,
      );
      RefRegistry.disposeGroup('stale-group');
      // staleRef lookup now returns null — hard pre-dispatch error.

      final response = await aiTestTapHandler(
        'ext.aitest.tap',
        <String, String>{'ref': staleRef},
      );
      expect(
        response.errorCode,
        equals(developer.ServiceExtensionResponse.extensionError),
        reason: 'Stale ref (group disposed) must return .error, not silent OK.',
      );
    });
  });
}
