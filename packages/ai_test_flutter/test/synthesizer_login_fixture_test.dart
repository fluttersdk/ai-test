@TestOn('chrome')
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'package:ai_test_flutter/ai_test_flutter.dart';

import 'fixtures/login_form_fixture.dart';
import 'helpers/projection_dom_probe.dart';

// ---------------------------------------------------------------------------
// Synthesizer regression test: login-shape vendored fixture.
//
// Pumps a widget tree that mimics the magic_starter login form shape using
// top-level classes literally named MagicForm, WFormInput, WButton, WAnchor,
// WText, WFormCheckbox. The synthesizer runs against this tree and the test
// asserts it produces known-good testids.
//
// If Magic/Wind rename a public field (e.g. formData → _formData, or
// controller → _controller) the synthesizer falls back to
// `unknown.<typename>.<depth>` — and this test fails in CI, catching the
// regression before it reaches production.
// ---------------------------------------------------------------------------

void main() {
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

  testWidgets(
    'synthesizer produces known-good testids for the login-form fixture shape',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: buildLoginFormFixture()),
          ),
        ),
      );

      final projection = Projection();
      projection.runEmitForTesting();

      final mirrors = collectProjectionMirrors();
      final testids =
          mirrors.where((m) => m.testid != null).map((m) => m.testid!).toSet();

      // 1. Email input — WFormInput with formData['email'] resolved via
      //    reference-equality between widget.controller and the
      //    TextEditingController in MagicFormData.
      expect(
        testids,
        contains('input.email'),
        reason:
            'email WFormInput must resolve to input.email via formData reference equality',
      );

      // 2. Password input — same resolution path.
      expect(
        testids,
        contains('input.password'),
        reason: 'password WFormInput must resolve to input.password',
      );

      // 3. Sign-in button — WButton with WText('auth.login_title') child.
      //    Snake-case produces button.auth_login_title from the trans-key string.
      expect(
        testids,
        contains('button.auth_login_title'),
        reason:
            'WButton with auth.login_title text must produce button.auth_login_title',
      );

      // 4. Forgot-password link — WAnchor with WText('auth.forgot_password').
      expect(
        testids,
        contains('link.auth_forgot_password'),
        reason:
            'WAnchor with auth.forgot_password text must produce link.auth_forgot_password',
      );

      // 5. Register link — WAnchor with WText('auth.dont_have_account').
      expect(
        testids,
        contains('link.auth_dont_have_account'),
        reason:
            'WAnchor with auth.dont_have_account text must produce link.auth_dont_have_account',
      );

      // 6. Verify no unexpected unknown testids for the core login widgets.
      //    WButton/WAnchor/WFormInput should NEVER fall back to unknown.*.
      final unknownForCoreWidgets = testids.where(
        (id) =>
            id.startsWith('unknown.wbutton') ||
            id.startsWith('unknown.wanchor') ||
            id.startsWith('unknown.wforminput'),
      );
      expect(
        unknownForCoreWidgets,
        isEmpty,
        reason: 'Core login widgets must not fall back to unknown.* — '
            'a fallback means a Magic/Wind field rename broke the synthesizer',
      );
    },
  );
}
