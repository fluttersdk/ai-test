@TestOn('chrome')
library;

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/projection_dom_probe.dart';

void main() {
  // Each test owns the host DOM, so wipe the previous projection and any
  // leftover host element before pumping the next widget tree.
  setUp(() {
    final mount = createGlasspaneMount();
    mount.clearHost();
  });

  testWidgets('Projection emits a mirror div for a Text widget', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('Hello'))),
      ),
    );

    final projection = Projection();
    projection.runEmitForTesting();

    final mirrors = collectProjectionMirrors();
    expect(mirrors, isNotEmpty);

    // _extractText walks descendants, so every ancestor of the Text widget
    // also carries its data-text. The mirror that ALSO reports a text-y role
    // is the one tied to the Text widget itself.
    final textMirrors = mirrors.where((m) => m.text == 'Hello').toList();
    expect(textMirrors, isNotEmpty);

    // Every emitted mirror is positioned absolutely and is click-transparent.
    for (final mirror in textMirrors) {
      expect(mirror.style, contains('position:absolute'));
      expect(mirror.style, contains('pointer-events:none'));
      expect(mirror.role, isNotNull);
      expect(mirror.testid, isNotNull);
      expect(mirror.testid, isNotEmpty);
    }
  });

  testWidgets('Projection clears the host between successive emits', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('First'))),
      ),
    );

    final projection = Projection();
    projection.runEmitForTesting();

    final firstPass = collectProjectionMirrors();
    expect(firstPass.where((m) => m.text == 'First'), isNotEmpty);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('Second'))),
      ),
    );

    projection.runEmitForTesting();

    final secondPass = collectProjectionMirrors();
    // The previous frame's "First" mirror MUST be gone (V0 = full re-emit).
    expect(secondPass.where((m) => m.text == 'First'), isEmpty);
    expect(secondPass.where((m) => m.text == 'Second'), isNotEmpty);
  });

  testWidgets('Projection records a metrics sample per emit', (tester) async {
    tester.view.physicalSize = const Size(400, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('Sample'))),
      ),
    );

    final metrics = ProjectionMetrics(publishToJs: false);
    final projection = Projection(metrics: metrics);

    projection.runEmitForTesting();
    projection.runEmitForTesting();

    expect(metrics.snapshot().count, equals(2));
  });
}
