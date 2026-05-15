import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Writes [stable] to `window.__aiTestStable` so Playwright can wait on
/// `await page.waitForFunction(() => window.__aiTestStable === true)` before
/// driving interactions.
///
/// Selected by the conditional import in `projection.dart` whenever
/// `dart.library.js_interop` is available (web / dart2js / dart2wasm).
void publishStabilityFlag(bool stable) {
  globalContext['__aiTestStable'] = stable.toJS;
}
