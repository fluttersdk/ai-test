import 'package:web/web.dart' as web;

import 'dom_emitter.dart';

/// Web implementation of [DomEmitter] using `package:web` directly.
class _WebDomEmitter implements DomEmitter {
  @override
  void clearHost(Object host) {
    final element = host as web.HTMLElement;
    // textContent='' is the cheapest cross-browser child-eviction path and
    // avoids the JS-variadic `replaceChildren` interop ceremony.
    element.textContent = '';
  }

  @override
  void appendMirror(
    Object host, {
    required String testid,
    required String role,
    String? text,
    required String styleCss,
  }) {
    final parent = host as web.HTMLElement;
    final div = web.document.createElement('div') as web.HTMLDivElement;
    div.setAttribute('data-testid', testid);
    div.setAttribute('data-role', role);
    if (text != null) {
      div.setAttribute('data-text', text);
    }
    div.setAttribute('style', styleCss);
    parent.appendChild(div);
  }
}

DomEmitter createDomEmitter() => _WebDomEmitter();
