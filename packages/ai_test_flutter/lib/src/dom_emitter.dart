/// Cross-platform contract for emitting one mirror `<div>` into the
/// projection host element.
///
/// The interface is intentionally typed with `Object` for the host so it
/// compiles on the Dart VM where `package:web` types are unavailable. The
/// web implementation casts `host` back to `HTMLElement` at the call site.
///
/// The factory [createDomEmitter] is published via the conditional export
/// below: web targets receive the real `_WebDomEmitter`; everything else
/// receives a stub whose methods throw [UnsupportedError].
library;

export 'dom_emitter_stub.dart'
    if (dart.library.js_interop) 'dom_emitter_web.dart';

abstract interface class DomEmitter {
  /// Removes every child of [host] in preparation for the next emit.
  void clearHost(Object host);

  /// Appends one mirror `<div>` to [host] with the supplied attributes.
  ///
  /// [styleCss] must be a complete inline `style` value (no key=value
  /// parsing happens here).
  void appendMirror(
    Object host, {
    required String testid,
    required String role,
    String? text,
    required String styleCss,
  });
}
