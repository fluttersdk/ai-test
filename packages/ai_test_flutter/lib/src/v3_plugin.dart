import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
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
/// Beyond extension registration, [install] also guards against duplicate
/// deferred-pump scheduling via an internal [_installCount] counter. On
/// hot-restart the static counter resets to zero (statics re-run their
/// initializers), so the first real call after restart performs full setup.
/// A second call within the same isolate lifetime (e.g. a test calling
/// [install] twice) increments the counter and returns early before reaching
/// [_pumpInterceptorRegistration], preventing a duplicate Timer-backoff loop
/// that would race the first. The VM extension table is unaffected because
/// [registerExtensionIdempotent] already handles that layer separately.
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
  /// Guarded by two early-return checks (in order):
  ///
  /// 1. **A3 env-var kill-switch** — reads [aiTestDisableEnvValue], which
  ///    defaults to `String.fromEnvironment('AI_TEST_DISABLE', defaultValue:
  ///    '')`. When non-empty AND truthy (`'1'`, `'true'`, `'yes'`, any case),
  ///    the method logs a skip message and returns immediately without
  ///    registering anything. Pass `--dart-define=AI_TEST_DISABLE=1` at build
  ///    time to activate. Note: `String.fromEnvironment` is a compile-time
  ///    constant; web targets have no `Platform.environment`, so
  ///    `--dart-define` is the correct mechanism.
  ///
  /// 2. **A2 idempotency guard** — [_installCount] counter prevents duplicate
  ///    [_pumpInterceptorRegistration] Timer-backoff loops on hot-restart.
  ///
  /// Logs `[ai-test-v3] installed (kDebugMode=$kDebugMode, isWeb=$kIsWeb)` on
  /// the first successful call so devtools captures the activation timeline.
  static void install() {
    // A3 guard: compile-time env-var kill-switch. String.fromEnvironment is
    // used (not Platform.environment) because web targets have no
    // Platform.environment. --dart-define=AI_TEST_DISABLE=1 bakes the value
    // at build time; it reads as a literal string at runtime.
    //
    // aiTestDisableEnvValue is exposed as @visibleForTesting so tests can
    // override it without recompiling with --dart-define.
    final String disableValue = aiTestDisableEnvValue.toLowerCase().trim();
    if (disableValue == '1' ||
        disableValue == 'true' ||
        disableValue == 'yes') {
      developer.log(
        '[ai-test-v3] install() skipped — '
        'AI_TEST_DISABLE=$aiTestDisableEnvValue set.',
        name: 'ai-test',
      );
      return;
    }

    // A2 guard: per-extension registerExtensionIdempotent calls AND the
    // _semanticsHandle ??= null-guard below are already idempotent. The actual
    // risk this guard addresses is _pumpInterceptorRegistration(): on
    // hot-restart, a second install() schedules a duplicate Timer-based
    // backoff loop that races the first. Guarding install() prevents that
    // duplicate scheduling.
    if (_installCount > 0) {
      developer.log(
        '[ai-test-v3] install() called ${_installCount + 1} times — '
        'skipping duplicate.',
        name: 'ai-test',
      );
      _installCount++;
      return;
    }
    _installCount++;

    // 1. The root RepaintBoundary key is created at static-init time; install
    //    is the gate that signals "the plugin is now active". No mutation
    //    needed here — main.dart wraps the boundary using this key.

    // 2. Force the Semantics tree on. Without this the snapshot extension
    //    walks a null SemanticsOwner and returns an empty YAML, breaking
    //    every ref-based action tool downstream. SemanticsHandle is retained
    //    as a static so the GC does not collapse it.
    _semanticsHandle ??= RendererBinding.instance.ensureSemantics();

    // 3. Wire auto-collecting helpers. Both register() calls are idempotent
    //    so repeated install() calls (hot-restart or test re-entry) are safe.
    //    AiTestHttpInterceptor.register() may early-return when Magic's
    //    network service is not yet bound (install() typically runs before
    //    Magic.init() in main.dart); the retry pump below catches that case.
    AiTestHttpInterceptor.register();
    AiTestLogSink.register();

    // 4. Deferred interceptor pump: AiTestHttpInterceptor.register() leaves
    //    itself unregistered when Magic.bound('network') is false. Schedule
    //    short follow-up attempts so it lands once Magic.init() completes,
    //    without forcing main.dart to reorder its boot sequence.
    _pumpInterceptorRegistration();

    // 5. Register every ext.aitest.* extension. The aggregator routes through
    //    registerExtensionIdempotent, so a second install() call is safe.
    registerAllAiTestExtensions();

    // 6. Surface the activation in devtools.
    developer.log(
      '[ai-test-v3] installed (kDebugMode=$kDebugMode, isWeb=$kIsWeb)',
      name: 'ai-test',
    );
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Counts how many times [install] has been called within this isolate
  /// lifetime. Zero means not yet installed; 1 means fully installed; 2+
  /// means duplicate guard fired. Resets to zero on hot-restart (statics
  /// re-run their initializers), which is the correct behavior: the new
  /// isolate-start after restart should perform a fresh full install.
  static int _installCount = 0;

  /// Exposes [_installCount] for test assertions.
  ///
  /// Production code must not read this. Tests use it to verify the A2
  /// guard fires on repeated [install] calls without triggering duplicate
  /// [_pumpInterceptorRegistration] scheduling.
  @visibleForTesting
  static int get installCount => _installCount;

  /// The value read by the A3 env-var kill-switch inside [install].
  ///
  /// Defaults to `String.fromEnvironment('AI_TEST_DISABLE', defaultValue: '')`
  /// which is baked at compile time via `--dart-define=AI_TEST_DISABLE=1`.
  /// Exposed as a mutable static so tests can override it without recompiling
  /// with a `--dart-define` flag (runtime `String.fromEnvironment` always
  /// returns the compile-time constant; there is no other way to inject the
  /// value in tests).
  @visibleForTesting
  static String aiTestDisableEnvValue = const String.fromEnvironment(
    'AI_TEST_DISABLE',
    defaultValue: '',
  );

  /// Retained Semantics handle so the engine keeps building the accessibility
  /// tree for the lifetime of the plugin (the snapshot extension walks it).
  static SemanticsHandle? _semanticsHandle;

  /// Backoff schedule for the deferred Magic-bound interceptor retry. Stops
  /// after the last attempt regardless of outcome — production launches
  /// finish Magic.init() well within 5 s on Flutter web.
  static const List<Duration> _interceptorRetryDelays = <Duration>[
    Duration(milliseconds: 100),
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
  ];

  /// Schedules follow-up [AiTestHttpInterceptor.register] calls until the
  /// interceptor reports as registered. Each delay runs as a fresh
  /// micro/macrotask; the chain bails out as soon as registration succeeds.
  static void _pumpInterceptorRegistration() {
    if (AiTestHttpInterceptor.isRegistered) return;
    for (final Duration delay in _interceptorRetryDelays) {
      Timer(delay, () {
        if (AiTestHttpInterceptor.isRegistered) return;
        AiTestHttpInterceptor.register();
      });
    }
  }
}
