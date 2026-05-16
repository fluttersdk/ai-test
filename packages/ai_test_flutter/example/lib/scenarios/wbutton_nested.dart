import 'package:flutter/material.dart';

/// Scenario 1 — D2 regression guard.
///
/// Renders the shape that Wind's `WButton` (and Material `InkWell`) ultimately
/// produces: a single ancestor recognizer wrapping a Row of an Icon and Text.
/// The interactive surface (`onTap`) lives on the OUTER widget; the inner
/// Text and Icon have no recognizers of their own.
///
/// Pre-D2, the snapshot ref system could resolve to the inner Text and tap
/// dispatch would miss the ancestor recognizer because the old
/// `_invokeTapCallback` fallback only inspected the element's direct widget.
/// Post-D2, [GestureBinding.handlePointerEvent] hits the render tree and the
/// gesture arena fires the ancestor recognizer regardless of which descendant
/// the ref points at.
///
/// The on-screen counter exposes the recognizer's fire count so integration
/// tests can assert the increment without inspecting Wind internals.
class WButtonNestedScenario extends StatefulWidget {
  const WButtonNestedScenario({super.key});

  /// Label rendered inside the InkWell's child Row. Tests look it up with
  /// `find.text(WButtonNestedScenario.label)` so the value is exposed as a
  /// static rather than re-typed in the test file.
  static const String label = 'Click me';

  @override
  State<WButtonNestedScenario> createState() => _WButtonNestedScenarioState();
}

class _WButtonNestedScenarioState extends State<WButtonNestedScenario> {
  int _taps = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WButton nested (D2)')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            // 1. Counter display — integration test assertion target.
            Text(
              'Taps: $_taps',
              style: const TextStyle(fontSize: 20),
            ),
            const SizedBox(height: 24),
            // 2. Ancestor recognizer (InkWell) wrapping an inner Row whose
            //    children have no recognizers of their own. This is the shape
            //    Wind's WButton produces in practice.
            Material(
              color: Colors.blue.shade100,
              child: InkWell(
                onTap: () => setState(() => _taps += 1),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.touch_app),
                      SizedBox(width: 8),
                      Text(
                        WButtonNestedScenario.label,
                        style: TextStyle(fontSize: 16),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
