@TestOn('chrome')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'helpers/projection_dom_probe.dart';

void main() {
  // Each test owns the host DOM. V0's createGlasspaneMount() always appends
  // a fresh host div on each ensureHost() call; orphan hosts from prior
  // tests stay in the shadow root and confuse `querySelector('#ai-test-host')`.
  // Manually purge any stale hosts so each test starts with a clean slate.
  // Also clear debugOnProfilePaint so a prior test's wiring does not leak.
  setUp(() {
    debugOnProfilePaint = null;
    final shadow = web.document.querySelector('flt-glass-pane')?.shadowRoot;
    if (shadow != null) {
      final stale = shadow.querySelectorAll('#ai-test-host');
      for (var i = 0; i < stale.length; i++) {
        final node = stale.item(i);
        if (node != null) {
          node.parentNode?.removeChild(node);
        }
      }
    }
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

  testWidgets(
    'Projection updates mirror text in place across successive emits',
    (tester) async {
      tester.view.physicalSize = const Size(400, 200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('First'))),
        ),
      );

      final projection = Projection();
      // V1 diff-update path requires the per-frame repaint hook so the
      // second emit recognises the changed Text and bypasses the
      // clean-subtree short-circuit.
      projection.activate();
      projection.runEmitForTesting();

      final firstPass = collectProjectionMirrors();
      expect(firstPass.where((m) => m.text == 'First'), isNotEmpty);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('Second'))),
        ),
      );

      // The post-frame _emit re-armed by the prior emit consumes the
      // repaint set populated during pumpWidget; that callback updates
      // mirrors in-place via the diff path. The explicit second
      // runEmitForTesting() below is a defensive no-op (set already drained).
      projection.runEmitForTesting();

      final secondPass = collectProjectionMirrors();
      expect(secondPass.where((m) => m.text == 'First'), isEmpty);
      expect(secondPass.where((m) => m.text == 'Second'), isNotEmpty);

      // Restore the debug global so flutter_test's invariant check passes.
      debugOnProfilePaint = null;
    },
  );

  testWidgets(
    'stability flips true on first non-empty emit (V0 relaxed semantic)',
    (tester) async {
      tester.view.physicalSize = const Size(400, 200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('Stable'))),
        ),
      );

      final projection = Projection();
      // V0 relaxed semantic, restored at V1 Step 12: stable=true on the
      // first non-empty emit, even when consecutiveStableFrames is 0. Strict
      // >=2 was unreachable on real production screens (continuous
      // micro-repaints from polling, cursor blinks, time-display ticks).
      projection.runEmitForTesting();
      expect(
        globalContext['__aiTestStable']?.dartify(),
        isTrue,
        reason:
            'after emit 1: newRects.isNotEmpty => stable, even though counter = 0',
      );

      // Emit 2: identical rects → counter increments; still stable.
      projection.runEmitForTesting();
      expect(
        globalContext['__aiTestStable']?.dartify(),
        isTrue,
        reason: 'after emit 2: rects unchanged, still stable',
      );
    },
  );

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
