import 'package:flutter/rendering.dart';

// ---------------------------------------------------------------------------
// Per-element diff-state record.
//
// [hostElement] is the DOM node reference. It is typed [Object] — not a
// web-only HTMLElement — so this file compiles on the Dart VM where
// package:web is unavailable. Callers on web cast to HTMLElement at the
// dom_emitter web layer.
// ---------------------------------------------------------------------------

/// Diff-state record for a single mirror node in the shadow DOM projection.
///
/// Tracks the last committed values for a given widget's mirror element so
/// [Projection._emit] can skip DOM mutations for subtrees that have not
/// changed between frames.
class MirrorNode {
  /// The DOM node reference for this mirror element.
  ///
  /// Typed [Object] per the V0 cross-platform interface convention — cast to
  /// HTMLElement at the dom_emitter web layer. Never null after construction.
  final Object hostElement;

  /// The last-committed bounding rectangle for this mirror.
  Rect lastRect;

  /// The last-committed testid attribute value for this mirror.
  String lastTestid;

  /// The last-committed ARIA role attribute value, or null when absent.
  String? lastRole;

  /// The last-committed visible text content, or null when absent.
  String? lastText;

  /// Creates a [MirrorNode] with the given initial committed state.
  MirrorNode({
    required this.hostElement,
    required this.lastRect,
    required this.lastTestid,
    this.lastRole,
    this.lastText,
  });

  /// Returns true when any of the four mutable fields differ from the
  /// candidate values, indicating that the mirror DOM node must be updated.
  bool needsUpdate({
    required Rect newRect,
    required String newTestid,
    String? newRole,
    String? newText,
  }) {
    return lastRect != newRect ||
        lastTestid != newTestid ||
        lastRole != newRole ||
        lastText != newText;
  }

  /// Commits the new values as the current baseline after a DOM update.
  ///
  /// Call this immediately after [Projection._emitter.upsertMirror] completes
  /// so that the next frame can correctly short-circuit via [needsUpdate].
  void recordCommitted({
    required Rect rect,
    required String testid,
    String? role,
    String? text,
  }) {
    lastRect = rect;
    lastTestid = testid;
    lastRole = role;
    lastText = text;
  }
}
