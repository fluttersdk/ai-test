@TestOn('chrome')
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_test_flutter/ai_test_flutter.dart';

// ---------------------------------------------------------------------------
// Minimal stateful widget whose setState forces a repaint on its RenderObject.
// ---------------------------------------------------------------------------

class _Counter extends StatefulWidget {
  const _Counter({super.key});

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _count = 0;

  void increment() => setState(() => _count++);

  @override
  Widget build(BuildContext context) {
    return Text('count:$_count');
  }
}

void main() {
  group('Projection repaint set', () {
    testWidgets(
      'debugRepaintedThisFrameForTesting contains the RenderObject that '
      'repainted after a setState',
      (tester) async {
        tester.view.physicalSize = const Size(400, 200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        final counterKey = GlobalKey<_CounterState>();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: _Counter(key: counterKey),
              ),
            ),
          ),
        );

        final projection = Projection();

        // 1. Wire debugOnProfilePaint manually (not via activate(), which
        //    would also schedule a post-frame _emit; that emit drains the
        //    repaint set after every frame as part of the V1 diff loop, so
        //    the test would observe an empty set).
        debugOnProfilePaint = (RenderObject ro) {
          projection.debugRepaintedThisFrameForTesting.add(ro);
        };

        // 2. Trigger a setState on the child; pump one frame so Flutter
        //    paints and debugOnProfilePaint fires for every repainted node.
        counterKey.currentState!.increment();
        await tester.pump();

        // 3. The repaint set must contain at least one RenderObject after
        //    the frame that followed the setState.
        final repainted = projection.debugRepaintedThisFrameForTesting;
        expect(repainted, isNotEmpty);

        // 4. The specific RenderObject backing the _Counter subtree must
        //    be in the set (proving the hook fires for stateful subtrees).
        final counterElement = counterKey.currentContext!;
        final counterRenderObject = counterElement.findRenderObject();
        expect(counterRenderObject, isNotNull);
        expect(repainted, contains(counterRenderObject));

        // 5. Restore the global so flutter_test's invariant check passes.
        //    debugOnProfilePaint is a debug-level global; the framework
        //    asserts it is null between tests via debugAssertAllRenderVarsUnset.
        debugOnProfilePaint = null;
      },
    );
  });
}
