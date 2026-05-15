import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'binding.dart';
import 'extensions.dart';
import 'ready_signal_stub.dart'
    if (dart.library.js_interop) 'ready_signal_web.dart';

/// V2 implementation of [AiTestHost] — enables Flutter's native Semantics tree
/// and publishes the `window.__aiTestReady` JS global once the first frame
/// has been committed.
///
/// ## What [activate] does
///
/// 1. Calls `RendererBinding.instance.ensureSemantics()` so Flutter emits
///    `<flt-semantics>` ARIA nodes into the light DOM. `RendererBinding` is
///    used (not `SemanticsBinding`) to avoid the TextField + Navigator
///    interaction regression documented in Flutter issue #129324.
/// 2. Schedules a post-frame callback via [WidgetsBinding.addPostFrameCallback]
///    that calls [publishReady]. On the web target [publishReady] writes
///    `window.__aiTestReady = true`; on VM it is a no-op stub. Playwright's
///    `waitForFlutterReady` helper polls this flag to know when the app is
///    interactive.
///
/// ## Activation gate
///
/// Gate enforcement (`kIsWeb && kDebugMode`) lives in [AiTestBinding] upstream.
/// [activate] is called only when the gate passes, so no extra guard is needed
/// here.
///
/// ## Usage
///
/// ```dart
/// if (!kReleaseMode) {
///   AiTestBinding.ensureInitialized(host: AiTestPluginV2());
/// }
/// ```
class AiTestPluginV2 implements AiTestHost {
  /// Creates an [AiTestPluginV2].
  const AiTestPluginV2();

  /// Activates the V2 AI-test plugin.
  ///
  /// Enables Flutter Semantics via [RendererBinding.instance.ensureSemantics]
  /// and schedules [publishReady] for the next post-frame callback.
  ///
  /// Must be called at most once per application lifetime. [AiTestBinding]
  /// enforces idempotency — subsequent calls via [AiTestBinding.ensureInitialized]
  /// are no-ops.
  @override
  void activate() {
    // 1. Enable the Flutter Semantics tree so the web engine emits <flt-semantics>
    //    ARIA nodes into the light DOM. RendererBinding is used here instead of
    //    SemanticsBinding to sidestep the TextField + Navigator regression in
    //    Flutter issue #129324.
    RendererBinding.instance.ensureSemantics();

    // 2. Flip __aiTestReady after the first frame so Playwright's
    //    waitForFlutterReady knows the widget tree is interactive.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      publishReady();
    });

    // 3. Register VM Service extensions for ai_test_node MCP server access
    //    to app state (routes, form data, controller state).
    registerAiTestExtensions();
  }
}
