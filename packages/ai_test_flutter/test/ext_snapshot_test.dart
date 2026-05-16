library;

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:magic/magic.dart';

/// Tests for Step 6 — `ext.aitest.snapshot` extension + `RefRegistry`.
///
/// VM-target widget tests; the SemanticsOwner walk works on the test
/// binding. Each test enables semantics via `tester.ensureSemantics()`
/// before pumping the tree so the pipelineOwner exposes a non-null
/// `rootSemanticsNode` at snapshot time. The handle is disposed
/// **synchronously inside the test body** (not via `addTearDown`)
/// because the test framework's leak check runs before user-registered
/// tearDowns fire.
///
/// Five behaviours under test:
///   (a) basic walk produces YAML with `text "..."` lines for plain Text
///       and `button "..." [ref=eN]` lines for interactive widgets;
///   (b) calling snapshot twice on an unchanged tree yields the SAME
///       ref id for each interactive node (cache hit per
///       SemanticsNode.id);
///   (c) snapshot after a widget rebuild that produces a NEW
///       SemanticsNode returns a NEW ref id (no stale cache);
///   (d) refs are scoped: `RefRegistry.lookup('eN')` returns null after
///       `RefRegistry.disposeGroup(groupId)`;
///   (e) MagicForm enrichment: snapshot of
///       `MagicForm(child: TextField(controller: form['email']))`
///       emits `magicFormField: email` under the textbox ref entry.
void main() {
  group('RefRegistry', () {
    setUp(RefRegistry.resetForTesting);

    testWidgets('disposeGroup removes refs of its group only', (
      tester,
    ) async {
      // Pump a trivial widget so we have a real Element to register
      // against; registerForTesting accepts any Element handle.
      await tester.pumpWidget(const SizedBox.shrink());
      final Element element = tester.element(find.byType(SizedBox));

      // Two entries (no node → no dedupe → fresh tokens) under
      // different groups.
      final String tokenA = RefRegistry.registerForTesting(
        rect: const Rect.fromLTWH(0, 0, 10, 10),
        element: element,
        groupId: 'group-A',
        isTextField: false,
      );
      final String tokenB = RefRegistry.registerForTesting(
        rect: const Rect.fromLTWH(0, 0, 10, 10),
        element: element,
        groupId: 'group-B',
        isTextField: false,
      );

      expect(RefRegistry.lookup(tokenA), isNotNull);
      expect(RefRegistry.lookup(tokenB), isNotNull);

      RefRegistry.disposeGroup('group-A');

      expect(RefRegistry.lookup(tokenA), isNull);
      expect(RefRegistry.lookup(tokenB), isNotNull);
    });
  });

  group('aiTestSnapshotHandler', () {
    setUp(RefRegistry.resetForTesting);

    testWidgets(
      '(a) basic walk emits text lines and ref-tagged button lines',
      (tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  const Text('Hello'),
                  ElevatedButton(
                    onPressed: () {},
                    child: const Text('Click'),
                  ),
                ],
              ),
            ),
          ),
        );

        final Map<String, dynamic> result = await aiTestSnapshotBuild();
        final String yaml = result['snapshot'] as String;

        // Plain text appears as a non-interactive line.
        expect(yaml, contains('text "Hello"'));

        // Button appears with role + label + ref.
        expect(yaml, matches(RegExp(r'button "Click" \[ref=e\d+\]')));

        // Result envelope keys are present.
        expect(result['groupId'], isA<String>());
        expect(result['groupId'] as String, startsWith('snapshot-'));

        handle.dispose();
      },
    );

    testWidgets(
      '(b) repeated snapshot of the unchanged tree returns the same ref',
      (tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ElevatedButton(
                onPressed: () {},
                child: const Text('Click'),
              ),
            ),
          ),
        );

        final String firstYaml =
            (await aiTestSnapshotBuild())['snapshot'] as String;
        final String secondYaml =
            (await aiTestSnapshotBuild())['snapshot'] as String;

        final RegExp refPattern = RegExp(r'\[ref=(e\d+)\]');
        final String? firstRef = refPattern.firstMatch(firstYaml)?.group(1);
        final String? secondRef = refPattern.firstMatch(secondYaml)?.group(1);

        expect(firstRef, isNotNull);
        expect(secondRef, isNotNull);
        expect(firstRef, equals(secondRef));

        handle.dispose();
      },
    );

    testWidgets(
      '(c) snapshot after rebuild that creates a new SemanticsNode emits a new ref',
      (tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();

        // First widget: a button.
        await tester.pumpWidget(
          MaterialApp(
            key: const ValueKey<String>('app-1'),
            home: Scaffold(
              body: ElevatedButton(
                onPressed: () {},
                child: const Text('First'),
              ),
            ),
          ),
        );
        final String firstYaml =
            (await aiTestSnapshotBuild())['snapshot'] as String;

        // Second widget: a different button under a fresh MaterialApp
        // key forces the underlying SemanticsNode tree to rebuild.
        await tester.pumpWidget(
          MaterialApp(
            key: const ValueKey<String>('app-2'),
            home: Scaffold(
              body: ElevatedButton(
                onPressed: () {},
                child: const Text('Second'),
              ),
            ),
          ),
        );
        final String secondYaml =
            (await aiTestSnapshotBuild())['snapshot'] as String;

        final RegExp refPattern = RegExp(r'\[ref=(e\d+)\]');
        final String? firstRef = refPattern.firstMatch(firstYaml)?.group(1);
        final String? secondRef = refPattern.firstMatch(secondYaml)?.group(1);

        expect(firstRef, isNotNull);
        expect(secondRef, isNotNull);
        expect(firstRef, isNot(equals(secondRef)));

        handle.dispose();
      },
    );

    testWidgets(
      '(d) RefRegistry.lookup returns null after disposeGroup',
      (tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ElevatedButton(
                onPressed: () {},
                child: const Text('Click'),
              ),
            ),
          ),
        );

        final Map<String, dynamic> result = await aiTestSnapshotBuild();
        final String yaml = result['snapshot'] as String;
        final String groupId = result['groupId'] as String;

        final String? ref =
            RegExp(r'\[ref=(e\d+)\]').firstMatch(yaml)?.group(1);
        expect(ref, isNotNull);
        expect(RefRegistry.lookup(ref!), isNotNull);

        RefRegistry.disposeGroup(groupId);

        expect(RefRegistry.lookup(ref), isNull);

        handle.dispose();
      },
    );

    testWidgets(
      '(e) MagicForm enrichment emits magicFormField for the bound textbox',
      (tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();

        // MagicFormData with a single text field 'email'. We pump a
        // MagicForm wrapping a Material TextField that uses the same
        // controller exposed by `form['email']`. The snapshot walk must
        // attach `magicFormField: email` to the textbox ref entry.
        final MagicFormData form = MagicFormData(<String, dynamic>{
          'email': '',
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MagicForm(
                formData: form,
                child: TextField(
                  controller: form['email'],
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
              ),
            ),
          ),
        );

        final Map<String, dynamic> result = await aiTestSnapshotBuild();
        final String yaml = result['snapshot'] as String;

        // YAML contains a textbox ref.
        expect(yaml, matches(RegExp(r'textbox.*\[ref=e\d+\]')));

        // YAML contains the enrichment line for the bound field name.
        expect(yaml, contains('magicFormField: email'));

        form.dispose();
        handle.dispose();
      },
    );
  });

  group('aiTestSnapshotHandler — ServiceExtensionResponse envelope', () {
    setUp(RefRegistry.resetForTesting);

    testWidgets(
      'handler returns ServiceExtensionResponse without throwing',
      (tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();

        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: Text('Hello'))),
        );

        final response = await aiTestSnapshotHandler(
          'ext.aitest.snapshot',
          const <String, String>{},
        );

        // The handler returned a non-null response and did not throw.
        // The payload shape itself is asserted via the public builder
        // in (a)-(e); here we only verify the VM-Service-facing handler
        // is wired.
        expect(response, isNotNull);

        handle.dispose();
      },
    );
  });
}
