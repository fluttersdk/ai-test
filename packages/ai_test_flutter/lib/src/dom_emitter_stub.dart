import 'package:flutter/rendering.dart';

import 'dom_emitter.dart';
import 'mirror_node.dart';

/// Non-web no-op implementation of [DomEmitter].
///
/// The projection itself never runs off web, but the symbol must exist so
/// the VM compile target resolves.
class _StubDomEmitter implements DomEmitter {
  @override
  Object upsertMirror({
    required MirrorNode? existing,
    required Object host,
    required Rect rect,
    required String testid,
    String? role,
    String? text,
  }) {
    throw UnsupportedError('DomEmitter is web-only.');
  }

  @override
  void removeMirror(MirrorNode node) {
    throw UnsupportedError('DomEmitter is web-only.');
  }
}

DomEmitter createDomEmitter() => _StubDomEmitter();
