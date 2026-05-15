import 'package:flutter/rendering.dart';
import 'package:web/web.dart' as web;

import 'dom_emitter.dart';
import 'mirror_node.dart';

/// Web implementation of [DomEmitter] using `package:web` directly.
///
/// Both `upsertMirror` and `removeMirror` mutate single DOM nodes; the V0
/// full-clear path (assigning the empty string to the host element's
/// textContent) is gone. Orphan removal is per-node, driven by
/// [Projection._emit] when an indexed RenderObject is not visited during
/// the current frame.
class _WebDomEmitter implements DomEmitter {
  @override
  Object upsertMirror({
    required MirrorNode? existing,
    required Object host,
    required Rect rect,
    required String testid,
    String? role,
    String? text,
  }) {
    if (existing == null) {
      // 1. Create a fresh <div> mirror under host and set every attribute.
      final parent = host as web.HTMLElement;
      final div = web.document.createElement('div') as web.HTMLDivElement;
      _writeAttributes(div, rect, testid, role, text);
      parent.appendChild(div);
      return div;
    }

    // 2. Reuse existing host element; mutate style + dataset in place.
    final element = existing.hostElement as web.HTMLElement;
    _writeAttributes(element, rect, testid, role, text);
    return element;
  }

  @override
  void removeMirror(MirrorNode node) {
    final element = node.hostElement as web.HTMLElement;
    element.remove();
  }

  /// Writes the inline style + data attributes for a single mirror element.
  ///
  /// Always sets `data-testid` and `data-role`. When [text] is null the
  /// `data-text` attribute is removed so a re-used DOM node never carries
  /// stale text from a previous frame.
  void _writeAttributes(
    web.HTMLElement element,
    Rect rect,
    String testid,
    String? role,
    String? text,
  ) {
    element.setAttribute(
      'style',
      'position:absolute; '
          'left:${rect.left}px; '
          'top:${rect.top}px; '
          'width:${rect.width}px; '
          'height:${rect.height}px; '
          'pointer-events:none;',
    );
    element.setAttribute('data-testid', testid);
    if (role != null) {
      element.setAttribute('data-role', role);
    } else {
      element.removeAttribute('data-role');
    }
    if (text != null) {
      element.setAttribute('data-text', text);
    } else {
      element.removeAttribute('data-text');
    }
  }
}

DomEmitter createDomEmitter() => _WebDomEmitter();
