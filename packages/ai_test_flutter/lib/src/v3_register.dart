import 'dart:developer' as developer;

/// Registers a Dart VM Service custom extension idempotently.
///
/// Wraps [developer.registerExtension] so that re-registration of the same
/// `method` name does not throw. The Dart VM throws [ArgumentError] when the
/// same extension is registered twice; the V2 plugin guarded this with a
/// boolean `_registered` static, but that pattern survives hot-RELOAD only.
/// Hot-RESTART re-runs `main()` against the same isolate, which resets the
/// static to `false` while the VM extension table retains the prior entry —
/// the second `registerExtension` call then throws.
///
/// V3 drops the static flag and instead catches the [ArgumentError] at the
/// call site. Other [ArgumentError]s (validation errors on a malformed method
/// name, etc.) are rethrown so genuine bugs still surface.
///
/// Logs a warning on swallowed re-registration via [developer.log] under the
/// `ai-test` logger name so devtools shows it during local development.
///
/// Usage:
/// ```dart
/// registerExtensionIdempotent('ext.aitest.snapshot', aiTestSnapshotHandler);
/// ```
void registerExtensionIdempotent(
  String method,
  developer.ServiceExtensionHandler handler,
) {
  try {
    developer.registerExtension(method, handler);
  } on ArgumentError catch (e) {
    // 1. Discriminate the "already registered" case from other validation
    //    errors thrown by registerExtension (e.g. method name does not start
    //    with `ext.`). Only the duplicate-registration signal is swallowed;
    //    everything else is a genuine bug and must surface.
    final String message = e.toString();
    if (!message.contains('already registered')) {
      rethrow;
    }

    // 2. Swallow + log under the `ai-test` logger so devtools shows it during
    //    hot-restart. NO `_registered` static is kept (per V3 design): the VM
    //    extension table persists across hot-restart while a static would
    //    reset, so try/catch is the only safe primitive.
    developer.log(
      '[ai-test-v3] re-register $method swallowed: $e',
      name: 'ai-test',
    );
  }
}
