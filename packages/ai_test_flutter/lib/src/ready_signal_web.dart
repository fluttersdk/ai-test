import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Publishes the AI-test ready signal to the browser JS global context.
///
/// Sets `window.__aiTestReady = true` so Playwright's `waitForFlutterReady`
/// helper can poll the flag rather than relying on a fixed-time sleep.
///
/// Called exactly once from [AiTestPluginV2.activate]'s post-frame callback,
/// guaranteeing that Flutter's first frame has been committed before the flag
/// flips.
void publishReady() {
  globalContext['__aiTestReady'] = true.toJS;
}
