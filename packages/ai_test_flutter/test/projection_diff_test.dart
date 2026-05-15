@TestOn('chrome')
library;

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'helpers/projection_dom_probe.dart';

// ---------------------------------------------------------------------------
// Spy DomEmitter — records each upsert/remove call so the diff test can
// assert the V1 path was exercised (existing != null on the second emit) and
// no extra DOM writes happened for unchanged nodes.
// ---------------------------------------------------------------------------

class _SpyDomEmitter implements DomEmitter {
  final DomEmitter _inner;
  final List<_UpsertCall> upserts = <_UpsertCall>[];
  final List<MirrorNode> removes = <MirrorNode>[];

  _SpyDomEmitter(this._inner);

  @override
  Object upsertMirror({
    required MirrorNode? existing,
    required Object host,
    required Rect rect,
    required String testid,
    String? role,
    String? text,
  }) {
    final result = _inner.upsertMirror(
      existing: existing,
      host: host,
      rect: rect,
      testid: testid,
      role: role,
      text: text,
    );
    upserts.add(
      _UpsertCall(
        existingWasNull: existing == null,
        rect: rect,
        testid: testid,
        role: role,
        text: text,
      ),
    );
    return result;
  }

  @override
  void removeMirror(MirrorNode node) {
    _inner.removeMirror(node);
    removes.add(node);
  }
}

class _UpsertCall {
  final bool existingWasNull;
  final Rect rect;
  final String testid;
  final String? role;
  final String? text;

  _UpsertCall({
    required this.existingWasNull,
    required this.rect,
    required this.testid,
    required this.role,
    required this.text,
  });
}

// ---------------------------------------------------------------------------
// Stateful widget whose setState swaps the displayed Text content. Used to
// prove that exactly one mirror's data-text mutates while host child count
// stays constant.
// ---------------------------------------------------------------------------

class _SwapText extends StatefulWidget {
  const _SwapText({super.key});

  @override
  State<_SwapText> createState() => _SwapTextState();
}

class _SwapTextState extends State<_SwapText> {
  String _value = 'Original';

  void swap(String next) => setState(() => _value = next);

  @override
  Widget build(BuildContext context) {
    return Text(_value);
  }
}

void main() {
  setUp(() {
    // V0's createGlasspaneMount() always appends a fresh host div on each
    // ensureHost() call; orphan hosts from prior tests stay in the shadow
    // root and confuse `querySelector('#ai-test-host')`. Manually purge any
    // stale hosts so each test starts with a clean slate.
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

  testWidgets(
    'Second emit with no widget changes reuses existing mirrors '
    '(diff path: existing != null, host children stable)',
    (tester) async {
      tester.view.physicalSize = const Size(600, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                Text('Alpha'),
                Text('Beta'),
                Text('Gamma'),
              ],
            ),
          ),
        ),
      );

      final spy = _SpyDomEmitter(createDomEmitter());
      final projection = Projection(emitter: spy);

      // Wire debugOnProfilePaint manually (NOT via activate(), which would
      // also schedule a post-frame _emit that drains the repaint set before
      // the test's runEmitForTesting() can read it).
      debugOnProfilePaint = (RenderObject ro) {
        projection.debugRepaintedThisFrameForTesting.add(ro);
      };

      // First emit: every mirror is freshly created (existing == null).
      projection.runEmitForTesting();
      final firstChildCount = collectProjectionMirrors().length;
      expect(firstChildCount, greaterThanOrEqualTo(3));
      expect(
        spy.upserts.where((c) => c.existingWasNull).length,
        equals(firstChildCount),
      );

      final firstUpsertCount = spy.upserts.length;

      // Second emit with NO tree change: every mirror lookup hits the index
      // and (a) the diff short-circuits (no upsert call at all for the clean
      // subtree) OR (b) upsert is called with existing != null and no DOM
      // mutation. Either way: zero new mirrors created, host child count
      // unchanged, no removeMirror called.
      projection.runEmitForTesting();

      final secondChildCount = collectProjectionMirrors().length;
      expect(
        secondChildCount,
        equals(firstChildCount),
        reason: 'Diff path must not re-create or drop mirrors',
      );
      expect(
        spy.removes,
        isEmpty,
        reason: 'No mirrors should be removed when tree is unchanged',
      );

      // Any upsert calls made during the second emit must have existing != null.
      final secondPassUpserts = spy.upserts.skip(firstUpsertCount);
      for (final call in secondPassUpserts) {
        expect(
          call.existingWasNull,
          isFalse,
          reason: 'Second emit must reuse existing MirrorNodes',
        );
      }

      debugOnProfilePaint = null;
    },
  );

  testWidgets(
    'setState swapping one Text mutates exactly that mirror; '
    'host children count stays unchanged',
    (tester) async {
      tester.view.physicalSize = const Size(600, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final swapKey = GlobalKey<_SwapTextState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                const Text('Static One'),
                _SwapText(key: swapKey),
                const Text('Static Two'),
              ],
            ),
          ),
        ),
      );

      final projection = Projection();
      // Wire debugOnProfilePaint manually so paint events accumulate into the
      // projection's set without scheduling an extra _emit (which would drain
      // the set before the test's second runEmitForTesting() can read it).
      debugOnProfilePaint = (RenderObject ro) {
        projection.debugRepaintedThisFrameForTesting.add(ro);
      };
      projection.runEmitForTesting();

      final beforeCount = collectProjectionMirrors().length;
      final beforeTexts =
          collectProjectionMirrors().map((m) => m.text).toList();
      expect(
        beforeTexts.where((t) => t == 'Original'),
        isNotEmpty,
      );

      // Swap the text content via setState; pump so Flutter rebuilds + paints.
      swapKey.currentState!.swap('Updated');
      await tester.pump();

      projection.runEmitForTesting();

      final afterMirrors = collectProjectionMirrors();
      final afterCount = afterMirrors.length;
      final afterTexts = afterMirrors.map((m) => m.text).toList();

      expect(
        afterCount,
        equals(beforeCount),
        reason: 'Host child count must not change when only content swapped',
      );
      expect(
        afterTexts.where((t) => t == 'Original'),
        isEmpty,
        reason: 'Old text must be gone after diff update',
      );
      expect(
        afterTexts.where((t) => t == 'Updated'),
        isNotEmpty,
        reason: 'New text must appear in at least one mirror',
      );

      debugOnProfilePaint = null;
    },
  );
}
