library;

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_test_flutter/src/ext_scroll.dart';

/// Tests for [registerScrollExtensions] (Step 9 of V3 plan).
///
/// Runs on the VM target — scroll position changes do not require a browser.
///
/// ## Async pattern (matches `ext_pointer_test.dart`)
///
/// Extension handlers call `WidgetsBinding.instance.endOfFrame` internally,
/// which in widget tests only completes after `tester.pump()`. We must
/// kick off the handler future, pump frames to advance `endOfFrame`, and
/// only then await the returned response. Awaiting the handler before
/// pumping deadlocks the fake-async test binding.
///
/// Asserts:
/// 1. `ext.aitest.scroll` with `dy` scrolls the root scrollable's position.
/// 2. `ext.aitest.scroll` with `intoView=true` calls ensureVisible on the
///    target element so it becomes visible (offset changes from zero).
/// 3. `ext.aitest.select_option` with a [DropdownButton] calls onChanged with
///    the given value.
void main() {
  group('aiTestScrollHandler', () {
    testWidgets(
      'scrolling by dy changes the scroll position of the root scrollable',
      (WidgetTester tester) async {
        // Arrange: a ListView with enough items that offset 0 is well below
        // item 15 (each item is 100px tall → item at offset 1000 is item 10).
        tester.view.physicalSize = const Size(400, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: scrollController,
                itemCount: 30,
                itemBuilder: (context, index) => SizedBox(
                  height: 100,
                  child: Text('Item $index'),
                ),
              ),
            ),
          ),
        );

        // Verify starting position.
        expect(scrollController.position.pixels, equals(0.0));

        // Act: kick off the handler (do NOT await yet — the handler awaits
        // `endOfFrame` which only completes after `tester.pump()`).
        final Future<developer.ServiceExtensionResponse> future =
            aiTestScrollHandler(
          'ext.aitest.scroll',
          {'dy': '500'},
        );

        // Pump to advance the endOfFrame awaits inside the handler.
        await tester.pump();
        await tester.pump();

        // Now collect the response.
        final response = await future;

        // Assert: response claims scrolled=true and final offset reflects dy.
        final decoded = jsonDecode(response.result!) as Map<String, dynamic>;
        expect(decoded['scrolled'], isTrue);
        expect(scrollController.position.pixels, greaterThan(0.0));
      },
    );

    testWidgets(
      'intoView=true scrolls so target element is visible',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(400, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        final scrollController = ScrollController();
        addTearDown(scrollController.dispose);

        // A key to identify the target widget deep in the list.
        final targetKey = GlobalKey();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                controller: scrollController,
                child: Column(
                  children: [
                    // 1000px of spacer to push the target off screen.
                    const SizedBox(height: 1000),
                    SizedBox(
                      key: targetKey,
                      height: 100,
                      child: const Text('Target'),
                    ),
                    const SizedBox(height: 1000),
                  ],
                ),
              ),
            ),
          ),
        );

        // Confirm target is off screen initially.
        expect(scrollController.position.pixels, equals(0.0));

        // Find the element associated with the target key.
        final BuildContext targetContext = targetKey.currentContext!;

        // Act: kick off ensureVisible (returns a Future that completes after
        // the 300ms animation — must be advanced via tester.pump()).
        final Future<void> future = aiTestScrollEnsureVisible(
          targetContext,
          alignment: 0.5,
          duration: const Duration(milliseconds: 300),
        );

        // Advance the animation in fake-async time.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        await future;

        // Assert: the scroll position has moved past zero.
        expect(scrollController.position.pixels, greaterThan(0.0));
      },
    );
  });

  group('aiTestSelectOptionHandler', () {
    testWidgets(
      'select_option on DropdownButton fires onChanged with the given value',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(400, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        String? selectedValue;
        final dropdownKey = GlobalKey();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DropdownButton<String>(
                key: dropdownKey,
                value: 'a',
                items: const [
                  DropdownMenuItem(value: 'a', child: Text('Option A')),
                  DropdownMenuItem(value: 'b', child: Text('Option B')),
                ],
                onChanged: (value) => selectedValue = value,
              ),
            ),
          ),
        );

        // Act: call select_option with the target element's context.
        final BuildContext dropdownContext = dropdownKey.currentContext!;
        final bool invoked = aiTestSelectOptionInElement(
          dropdownContext,
          value: 'b',
        );

        // Assert: onChanged was invoked with the correct value.
        expect(invoked, isTrue);
        expect(selectedValue, equals('b'));
      },
    );
  });
}
