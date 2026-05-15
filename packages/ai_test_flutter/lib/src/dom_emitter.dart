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

import 'package:flutter/rendering.dart';

import 'mirror_node.dart';

export 'dom_emitter_stub.dart'
    if (dart.library.js_interop) 'dom_emitter_web.dart';

abstract interface class DomEmitter {
  /// Creates a new mirror DOM node OR mutates an existing one in place.
  ///
  /// When [existing] is `null`, the implementation creates a new `<div>` host
  /// inside [host], sets the `data-testid` / `data-role` / `data-text`
  /// attributes plus inline `style` from [rect], and returns the newly
  /// created element reference (typed [Object] for cross-platform compile).
  ///
  /// When [existing] is non-null, the implementation reads the cached host
  /// element from [MirrorNode.hostElement], mutates `style.left/top/width/
  /// height` and `data-*` attributes in place, and returns the same element
  /// reference. No new DOM node is created — this is the V1 diff path that
  /// avoids the per-frame full re-emit cost.
  ///
  /// Callers must wrap the returned reference into a fresh [MirrorNode] (when
  /// [existing] was null) or call [MirrorNode.recordCommitted] (when [existing]
  /// was non-null) to refresh the diff baseline before the next emit.
  Object upsertMirror({
    required MirrorNode? existing,
    required Object host,
    required Rect rect,
    required String testid,
    String? role,
    String? text,
  });

  /// Removes the mirror DOM node held by [node] from its parent host.
  ///
  /// Called by [Projection._emit] for every entry in the diff index whose
  /// keying RenderObject was not visited during the current emit (orphan
  /// detection). After the call, the caller must drop its [MirrorNode]
  /// reference from the diff index.
  void removeMirror(MirrorNode node);
}
