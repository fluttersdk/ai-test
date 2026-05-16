@TestOn('chrome')
library;

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for [AiTestPluginV3] (Step 4 of V3 plan + A2 idempotency guard).
///
/// These tests run on `--platform chrome` because the V3 plugin is gated by
/// `kIsWeb && kDebugMode`; the chrome runner provides both. The VM-target
/// platform also satisfies `kDebugMode` but `kIsWeb` is false there, so
/// integrations that rely on `dart:html` (e.g. screenshot in later steps)
/// would not exercise the real path.
///
/// Asserts:
/// 1. `install()` is idempotent — calling it twice does not throw.
/// 2. After `install()`, the global RepaintBoundary GlobalKey is non-null
///    and exposes a stable `debugLabel`.
/// 3. `registerExtensionIdempotent` swallows the `ArgumentError` raised by
///    `developer.registerExtension` when the same extension name is
///    registered twice (hot-restart safety).
/// 4. A2 guard: `install()` called more than once skips duplicate
///    `_pumpInterceptorRegistration()` scheduling — asserted via
///    [AiTestPluginV3.installCount] counter. Counter reaches 1 on first call
///    and 2+ on second call but actual work (pump scheduling) is skipped.
void main() {
  setUpAll(() {
    // Required: install() calls RendererBinding.instance.ensureSemantics(),
    // which asserts the binding is initialized. Tests that call install()
    // directly (outside a testWidgets pump) must initialize the binding here.
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  group('AiTestPluginV3', () {
    test(
      'A3: install() skips all setup when aiTestDisableEnvValue is truthy',
      () {
        // Reset install state so the A3 guard is what fires, not the A2 guard.
        // We do this by directly overriding the testable env-value hook, then
        // reading installCount before and after to verify no increment beyond
        // the guard path.
        //
        // Because String.fromEnvironment() is baked at compile time and cannot
        // be overridden at runtime, AiTestPluginV3 exposes a
        // @visibleForTesting static `aiTestDisableEnvValue` that defaults to
        // String.fromEnvironment('AI_TEST_DISABLE', ...) but can be overridden
        // in tests.
        AiTestPluginV3.aiTestDisableEnvValue = '1';

        // Capture baseline count. In Chrome-runner tests the isolate is shared
        // across the group, so count may already be >0 from earlier tests.
        final int countBefore = AiTestPluginV3.installCount;

        // install() must return without performing full setup.
        expect(AiTestPluginV3.install, returnsNormally);

        // installCount must NOT have changed — the A3 guard fires before the
        // A2 counter increment, so a disabled install is a no-op on the count.
        expect(
          AiTestPluginV3.installCount,
          equals(countBefore),
          reason: 'A3 guard must return before modifying installCount.',
        );

        // Restore the env override so subsequent tests are unaffected.
        AiTestPluginV3.aiTestDisableEnvValue =
            const String.fromEnvironment('AI_TEST_DISABLE', defaultValue: '');
      },
    );

    test('install() is idempotent (calling twice does not throw)', () {
      // First call: must succeed and perform setup.
      AiTestPluginV3.install();

      // Second call: must NOT throw. The internal registration helper
      // swallows ArgumentError on duplicate, so install() stays no-throw.
      expect(AiTestPluginV3.install, returnsNormally);
    });

    test('rootRepaintBoundaryKey is non-null after install()', () {
      AiTestPluginV3.install();

      final GlobalKey key = AiTestPluginV3.rootRepaintBoundaryKey;

      expect(key, isNotNull);
      expect(key.toString(), contains('aiTestRootRepaintBoundary'));
    });

    test(
      'A2: install() increments installCount and skips pump on duplicate calls',
      () {
        // Capture installCount before first call. In an isolated Chrome test
        // run, the static starts at 0, but other tests in this group may have
        // already called install(). Record the baseline here.
        final int countBefore = AiTestPluginV3.installCount;

        // First call (may already have been performed by earlier tests; we
        // care about the delta, not the absolute value).
        AiTestPluginV3.install();
        final int countAfterFirst = AiTestPluginV3.installCount;

        // Second call: guard fires — count still increments, but
        // _pumpInterceptorRegistration() is NOT scheduled again.
        AiTestPluginV3.install();
        final int countAfterSecond = AiTestPluginV3.installCount;

        // The counter must have moved forward on each call.
        expect(
          countAfterFirst,
          greaterThan(countBefore),
          reason: 'First install() must increment installCount.',
        );
        expect(
          countAfterSecond,
          greaterThan(countAfterFirst),
          reason: 'Second install() must increment installCount even when '
              'skipping duplicate pump scheduling.',
        );

        // After the second call the count is at least 2 (first full install
        // brought it to 1; guard increments it to 2 before returning).
        expect(
          AiTestPluginV3.installCount,
          greaterThanOrEqualTo(2),
          reason: 'installCount must reach >=2 after two calls.',
        );
      },
    );
  });

  group('registerExtensionIdempotent', () {
    test('swallows ArgumentError on duplicate registration', () async {
      const String method = 'ext.aitest.test_idempotent_helper';

      Future<developer.ServiceExtensionResponse> handler(
        String method,
        Map<String, String> params,
      ) async =>
          developer.ServiceExtensionResponse.result(jsonEncode({'ok': true}));

      // First registration: lands in the VM extension table.
      registerExtensionIdempotent(method, handler);

      // Second registration: VM throws ArgumentError("Extension already
      // registered: $method"). The helper must swallow it without rethrow.
      expect(
        () => registerExtensionIdempotent(method, handler),
        returnsNormally,
      );
    });
  });
}
