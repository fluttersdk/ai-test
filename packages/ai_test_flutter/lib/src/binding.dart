import 'package:flutter/foundation.dart';

// ---------------------------------------------------------------------------
// Public contract — implemented by the projection layer (Step 10).
// ---------------------------------------------------------------------------

/// Contract for the object that performs the actual Shadow DOM projection.
///
/// [AiTestBinding.ensureInitialized] delegates to [activate] when the
/// debug-mode + dart-define + URL-query gate passes. Implementation lives in
/// `Projection` (Step 10); tests supply a spy via this interface.
abstract class AiTestHost {
  /// Called exactly once after the gate passes.
  ///
  /// Must not be wrapped in try/catch at the call site — init errors must
  /// surface, not be swallowed.
  void activate();
}

// ---------------------------------------------------------------------------
// Binding — gate logic only. No projection here.
// ---------------------------------------------------------------------------

/// Installs the AI-test projection when the runtime conditions are met.
///
/// ## Activation gate
///
/// Activation requires ALL of:
/// 1. `kReleaseMode == false` — i.e. debug OR profile build. Release builds
///    are always a no-op; the binding tree-shakes cleanly under
///    `flutter build web --release`. Profile is included so per-frame
///    measurement reflects realistic dart2js-optimized cost (debug-mode
///    measurements are 2-5x inflated and useless for the spike's <3ms p95
///    acceptance threshold).
/// 2. At least one of the flag signals is `"1"`:
///    - The compile-time dart-define `AI_TEST` (set via
///      `--dart-define=AI_TEST=1`).
///    - The URL query parameter `aiTest` (e.g. `?aiTest=1`).
///
/// ## Dart-define literal constraint
///
/// `String.fromEnvironment('AI_TEST')` uses a **hardcoded string literal**
/// because `fromEnvironment` requires a compile-time constant as its first
/// argument for constant folding to work. The [dartDefineName] parameter
/// therefore affects **only documentation** (and the [overrideDartDefineValue]
/// test-override path). It does NOT change which dart-define is read at
/// runtime.
///
/// ## Idempotency
///
/// Once activated, subsequent calls are no-ops. This is safe for hot-reload
/// scenarios and for tests that must reset state explicitly via
/// [resetForTesting].
///
/// ## Usage in `main.dart`
///
/// ```dart
/// WidgetsFlutterBinding.ensureInitialized();
/// // Compile-time guard so dart2js tree-shakes Projection + transitive
/// // imports out of the release bundle.
/// if (!kReleaseMode) {
///   AiTestBinding.ensureInitialized(host: Projection());
/// }
/// MagicRouter.instance.addObserver(…);
/// await Magic.init(…);
/// ```
///
/// The `host:` argument is required to install the projection — passing
/// `null` (or omitting it) runs the gate but emits no mirror DOM.
class AiTestBinding {
  AiTestBinding._();

  static bool _activated = false;

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  /// Runs the activation gate and, when conditions are met, calls
  /// [host.activate()].
  ///
  /// Parameters in brackets are `@visibleForTesting` injection points so unit
  /// tests can drive every branch without live dart-defines or a real browser
  /// URL.
  ///
  /// - [dartDefineName]: documents which dart-define name this binding reads;
  ///   does NOT change the literal passed to [String.fromEnvironment].
  /// - [queryParamName]: the URL query parameter name to check (default
  ///   `aiTest`).
  /// - [host]: receives [AiTestHost.activate] when the gate passes. Pass
  ///   `null` to run the gate without a side-effect (rarely useful outside
  ///   tests).
  /// - [overrideDebugMode]: replaces [kDebugMode] for testing.
  /// - [overrideDartDefineValue]: replaces the compile-time `AI_TEST` read
  ///   for testing.
  /// - [overrideUri]: replaces [Uri.base] for testing.
  static void ensureInitialized({
    String dartDefineName = 'AI_TEST',
    String queryParamName = 'aiTest',
    AiTestHost? host,
    @visibleForTesting bool? overrideDebugMode,
    @visibleForTesting String? overrideDartDefineValue,
    @visibleForTesting Uri? overrideUri,
  }) {
    if (_activated) return;

    // 1. Resolve the non-release flag (debug OR profile, NOT release).
    //    Profile builds set kReleaseMode=false; spike measurement targets
    //    profile so this gate must accept it. Release tree-shakes the
    //    binding entirely.
    final bool isDebug = overrideDebugMode ?? !kReleaseMode;

    // 2. Resolve the dart-define signal.
    //    The literal 'AI_TEST' is intentionally hardcoded — see class docblock.
    final String dartDefineValue = overrideDartDefineValue ??
        const String.fromEnvironment('AI_TEST', defaultValue: '0');

    // 3. Resolve the URL query-param signal.
    final String queryParamValue =
        (overrideUri ?? Uri.base).queryParameters[queryParamName] ?? '0';

    // 4. Evaluate the activation predicate.
    final bool shouldActivate =
        isDebug && (dartDefineValue == '1' || queryParamValue == '1');

    if (!shouldActivate) return;

    _activated = true;
    host?.activate();
  }

  /// Resets internal state between tests.
  ///
  /// Must NOT be called from production code. Only the test setUp() should
  /// invoke this.
  @visibleForTesting
  static void resetForTesting() => _activated = false;
}
