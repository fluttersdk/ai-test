@TestOn('chrome')
library;

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for [AiTestPluginV3] (Step 4 of V3 plan).
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
void main() {
  group('AiTestPluginV3', () {
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
