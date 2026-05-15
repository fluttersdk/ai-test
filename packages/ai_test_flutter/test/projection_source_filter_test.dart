@TestOn('chrome')
library;

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/projection_dom_probe.dart';

// ---------------------------------------------------------------------------
// Synthetic widget classes literally named WFormInput and WInput so that
// widget.runtimeType.toString() returns those exact strings — matching what
// the production synthesizer and source-filter checks read.
//
// Dart's Object.runtimeType is NOT overridable; the ONLY reliable approach
// is to declare top-level classes with the exact desired names. These classes
// do NOT import package:fluttersdk_wind; they are self-contained fakes.
// ---------------------------------------------------------------------------

/// Fake outer form-input wrapper. Its runtimeType.toString() == 'WFormInput'.
class WFormInput extends StatelessWidget {
  final Widget child;

  const WFormInput({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // Wrap in a SizedBox so this widget owns its own RenderObject (RenderBox).
    return SizedBox(width: 200, height: 48, child: child);
  }
}

/// Fake inner input widget. Its runtimeType.toString() == 'WInput'.
class WInput extends StatelessWidget {
  final Widget child;

  const WInput({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // Wrap in a SizedBox so this widget also owns its own RenderObject.
    return SizedBox(width: 200, height: 48, child: child);
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUp(() {
    final mount = createGlasspaneMount();
    mount.clearHost();
  });

  testWidgets(
    'WInput mirror is suppressed when a WFormInput ancestor is present',
    (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      // Pump a tree: WFormInput -> WInput -> TextField.
      // WFormInput wraps WInput, which is the inner widget pattern from Wind.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: WFormInput(
                child: WInput(
                  child: TextField(controller: TextEditingController()),
                ),
              ),
            ),
          ),
        ),
      );

      final projection = Projection();
      projection.runEmitForTesting();

      final mirrors = collectProjectionMirrors();

      // Before the source-filter fix: both WFormInput and WInput produce
      // mirrors, so two mirrors share the same testid family (unknown.wforminput
      // and unknown.winput). After the fix: only WFormInput emits a mirror;
      // WInput is suppressed because it has a WFormInput ancestor.
      final wInputMirrors = mirrors.where(
        (m) => m.testid != null && m.testid!.contains('winput'),
      );
      expect(
        wInputMirrors,
        isEmpty,
        reason:
            'WInput mirror must be suppressed when inside a WFormInput ancestor',
      );
    },
  );

  testWidgets(
    'WFormInput mirror is still emitted when WInput is suppressed',
    (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: WFormInput(
                child: WInput(
                  child: TextField(controller: TextEditingController()),
                ),
              ),
            ),
          ),
        ),
      );

      final projection = Projection();
      projection.runEmitForTesting();

      final mirrors = collectProjectionMirrors();

      // The outer WFormInput must still produce its mirror.
      final wFormInputMirrors = mirrors.where(
        (m) => m.testid != null && m.testid!.contains('wforminput'),
      );
      expect(
        wFormInputMirrors,
        isNotEmpty,
        reason: 'WFormInput must still emit its mirror after source-filter',
      );
    },
  );

  testWidgets(
    'WInput outside a WFormInput still emits a mirror (no false suppression)',
    (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      // WInput standalone (no WFormInput ancestor) — must NOT be suppressed.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: WInput(
                child: TextField(controller: TextEditingController()),
              ),
            ),
          ),
        ),
      );

      final projection = Projection();
      projection.runEmitForTesting();

      final mirrors = collectProjectionMirrors();

      final wInputMirrors = mirrors.where(
        (m) => m.testid != null && m.testid!.contains('winput'),
      );
      expect(
        wInputMirrors,
        isNotEmpty,
        reason: 'WInput without a WFormInput ancestor must NOT be suppressed',
      );
    },
  );
}
