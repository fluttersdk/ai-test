@TestOn('chrome')
library;
// Chrome-only: JS-global assertions require the real web runtime.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    AiTestBinding.resetForTesting();
  });

  testWidgets(
    'activate() enables Flutter Semantics (RendererBinding.semanticsEnabled is true)',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      // Acquire a test-owned semantics handle so the flutter test framework can
      // verify clean disposal. activate() internally calls ensureSemantics() for
      // the production handle (app lifetime); this test handle tracks the same
      // semantics ownership and is disposed in addTearDown.
      final semanticsHandle = tester.ensureSemantics();
      addTearDown(semanticsHandle.dispose);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('hello'))),
      );

      AiTestPluginV2().activate();

      // One pump is enough: semanticsEnabled flips synchronously inside activate().
      await tester.pump();

      // V2 contract: RendererBinding has semantics enabled after activate().
      expect(RendererBinding.instance.semanticsEnabled, isTrue);
    },
  );

  testWidgets(
    'activate() sets window.__aiTestReady = true after first post-frame callback',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      // Acquire a test-owned semantics handle to satisfy the flutter test
      // framework's disposal check. activate() holds its own production handle.
      final semanticsHandle = tester.ensureSemantics();
      addTearDown(semanticsHandle.dispose);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('ready check'))),
      );

      AiTestPluginV2().activate();

      // One pump triggers the post-frame callback added by activate().
      await tester.pump();

      // V2 contract: __aiTestReady is true in JS globalThis after activate().
      final readyFlag = (globalContext['__aiTestReady'] as JSBoolean?)?.toDart;
      expect(readyFlag, isTrue);
    },
  );
}
