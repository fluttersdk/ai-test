import 'package:web/web.dart';

import 'glasspane_mount.dart';

/// Web implementation of [GlasspaneMount].
///
/// Locates `<flt-glass-pane>`, reads its open shadow root, and appends a
/// single `<div id="ai-test-host">` styled `position:absolute; pointer-events:none;`
/// so projection mirrors stack over the canvas without intercepting clicks.
///
/// Per Oracle Finding #2, the host MUST live inside the glass pane's shadow
/// root (sibling of `flt-scene-host`) — appending to `document.body` puts it
/// in the wrong coordinate space and breaks `page.mouse.click(x, y)` relay.
class _WebGlasspaneMount implements GlasspaneMount {
  static const String _hostId = 'ai-test-host';
  static const String _hostStyle =
      'position:absolute; top:0; left:0; pointer-events:none;';

  HTMLDivElement? _host;

  @override
  Object ensureHost() {
    final existing = _host;
    if (existing != null) return existing;

    final glassPane = document.querySelector('flt-glass-pane');
    if (glassPane == null) {
      throw StateError(
        'flt-glass-pane not found. Call ensureHost() after Flutter has '
        'rendered its first frame.',
      );
    }

    final shadowRoot = glassPane.shadowRoot;
    if (shadowRoot == null) {
      throw StateError('flt-glass-pane.shadowRoot is null.');
    }

    final div = document.createElement('div') as HTMLDivElement;
    div.id = _hostId;
    div.setAttribute('style', _hostStyle);
    shadowRoot.appendChild(div);

    _host = div;
    return div;
  }

  @override
  void clearHost() {
    final host = _host;
    if (host == null) return;
    host.remove();
    _host = null;
  }
}

/// Returns the web implementation of [GlasspaneMount].
GlasspaneMount createGlasspaneMount() => _WebGlasspaneMount();
