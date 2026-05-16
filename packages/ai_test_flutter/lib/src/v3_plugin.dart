import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'ai_test_http_interceptor.dart';
import 'ai_test_log_sink.dart';
import 'extensions.dart';
import 'v3_register.dart';

/// Entry point for the V3 ai_test_flutter plugin.
///
/// V3 replaces V2's Hybrid (Native Semantics + Playwright dual-chrome)
/// architecture with a single-channel MCP-only design: every interaction
/// flows through Dart VM Service custom extensions registered under
/// `ext.aitest.*`. This class hosts the install entry point and the shared
/// resources that every extension consumes (currently only the root
/// RepaintBoundary key used by the screenshot extension).
///
/// ## Lifecycle
///
/// `main.dart` calls [install] inside a compile-time guard:
///
/// ```dart
/// if (kIsWeb && kDebugMode) {
///   AiTestPluginV3.install();
///   runApp(
///     RepaintBoundary(
///       key: AiTestPluginV3.rootRepaintBoundaryKey,
///       child: MagicApplication(...),
///     ),
///   );
/// }
/// ```
///
/// The outer `kIsWeb && kDebugMode` guard lets `dart2js` tree-shake the
/// entire V3 branch out of release bundles. Release builds emit zero V3
/// bytes.
///
/// ## Idempotency
///
/// [install] is safe to call multiple times. Each `ext.aitest.*` registration
/// goes through [registerExtensionIdempotent], which catches the VM's
/// duplicate-registration [ArgumentError]. This keeps hot-restart safe (the
/// VM extension table persists across hot-restart, so a second install would
/// otherwise throw on the first extension).
///
/// ## RepaintBoundary
///
/// [rootRepaintBoundaryKey] is a [GlobalKey] that the host app must wrap
/// around its widget root. The screenshot extension (Step 11) reads
/// `key.currentContext.findRenderObject()` to obtain the
/// [RenderRepaintBoundary] for `toImage`. The plugin does NOT auto-wrap
/// `WidgetsApp`; main.dart owns the wrap so the boundary's parent stays
/// explicit.
class AiTestPluginV3 {
  AiTestPluginV3._();

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Global key for the root [RepaintBoundary] used by the screenshot
  /// extension. main.dart wraps the app root in
  /// `RepaintBoundary(key: AiTestPluginV3.rootRepaintBoundaryKey, child: ...)`
  /// inside the `kIsWeb && kDebugMode` gate.
  ///
  /// Exposed as a mutable static (not `final`) only to allow tests to swap
  /// the key in narrow scenarios; production code never reassigns it.
  static GlobalKey rootRepaintBoundaryKey = GlobalKey(
    debugLabel: 'aiTestRootRepaintBoundary',
  );

  /// Installs the V3 plugin: registers every `ext.aitest.*` VM Service
  /// extension and wires the auto-collecting helpers (Dio interceptor + log
  /// sink land in Step 5).
  ///
  /// Idempotent: subsequent calls re-enter the registration loop, which is
  /// itself idempotent via [registerExtensionIdempotent].
  ///
  /// Logs `[ai-test-v3] installed (kDebugMode=$kDebugMode, isWeb=$kIsWeb)` on
  /// every call so devtools captures the activation timeline.
  static void install() {
    // 1. The root RepaintBoundary key is created at static-init time; install
    //    is the gate that signals "the plugin is now active". No mutation
    //    needed here — main.dart wraps the boundary using this key.

    // 2. Wire auto-collecting helpers. Both register() calls are idempotent
    //    so repeated install() calls (hot-restart or test re-entry) are safe.
    AiTestHttpInterceptor.register();
    AiTestLogSink.register();

    // 3. Register every ext.aitest.* extension. The aggregator routes through
    //    registerExtensionIdempotent, so a second install() call is safe.
    registerAllAiTestExtensions();

    // 4. Surface the activation in devtools.
    developer.log(
      '[ai-test-v3] installed (kDebugMode=$kDebugMode, isWeb=$kIsWeb)',
      name: 'ai-test',
    );
  }
}
