import 'dom_emitter.dart';

/// Non-web no-op implementation of [DomEmitter].
///
/// The projection itself never runs off web, but the symbol must exist so
/// the VM compile target resolves.
class _StubDomEmitter implements DomEmitter {
  @override
  void clearHost(Object host) {
    throw UnsupportedError('DomEmitter is web-only.');
  }

  @override
  void appendMirror(
    Object host, {
    required String testid,
    required String role,
    String? text,
    required String styleCss,
  }) {
    throw UnsupportedError('DomEmitter is web-only.');
  }
}

DomEmitter createDomEmitter() => _StubDomEmitter();
