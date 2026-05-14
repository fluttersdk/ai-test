import 'package:web/web.dart' as web;

/// Returns true when [host] is a DOM Node attached inside the open shadow
/// root of `<flt-glass-pane>`.
///
/// The caller (test) only invokes this helper after asserting `kIsWeb`, and
/// the [host] value originates from `GlasspaneMount.ensureHost()` whose web
/// implementation returns an `HTMLDivElement`. Casting via `as web.Node` is
/// therefore safe and avoids the `invalid_runtime_check_with_js_interop_types`
/// analyzer warning that an `is web.Node` check would emit.
bool hostIsInsideGlassPaneShadowRoot(Object host) {
  final node = host as web.Node;

  final glassPane = web.document.querySelector('flt-glass-pane');
  if (glassPane == null) return false;

  final shadowRoot = glassPane.shadowRoot;
  if (shadowRoot == null) return false;

  web.Node? cursor = node.parentNode;
  while (cursor != null) {
    if (identical(cursor, shadowRoot)) return true;
    cursor = cursor.parentNode;
  }
  return false;
}
