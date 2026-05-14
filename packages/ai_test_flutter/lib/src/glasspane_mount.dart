/// Cross-platform contract for mounting the AI-test projection host inside
/// the Flutter web `<flt-glass-pane>` shadow root.
///
/// The interface intentionally returns [Object] (not a web-only DOM element
/// type) so it compiles on the Dart VM where `package:web` is unavailable.
/// Callers on web cast the result to the concrete DOM element type at the
/// call site.
///
/// The factory [createGlasspaneMount] is published via the conditional export
/// below: web targets receive the real `_WebGlasspaneMount`; everything else
/// (VM, mobile, desktop) receives a stub whose [ensureHost] throws.
library;

export 'glasspane_mount_stub.dart'
    if (dart.library.js_interop) 'glasspane_mount_web.dart';

abstract interface class GlasspaneMount {
  /// Returns the projection host element, creating it on first call and
  /// returning the same instance on every subsequent call (idempotent).
  ///
  /// On web: appends `<div id="ai-test-host">` inside
  /// `flt-glass-pane.shadowRoot` and returns the appended element.
  /// On non-web: throws [UnsupportedError].
  Object ensureHost();

  /// Removes the projection host from the DOM if present.
  ///
  /// No-op when [ensureHost] has not been called yet, or on non-web targets.
  void clearHost();
}
