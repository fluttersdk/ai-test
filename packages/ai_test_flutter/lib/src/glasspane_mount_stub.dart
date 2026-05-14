import 'glasspane_mount.dart';

/// Non-web no-op implementation of [GlasspaneMount].
///
/// Selected by the conditional export in `glasspane_mount.dart` whenever
/// `dart.library.js_interop` is unavailable (VM, mobile, desktop). Calling
/// [ensureHost] throws [UnsupportedError]; the projection layer never reaches
/// this code path because [AiTestBinding.ensureInitialized] gates activation
/// behind `kIsWeb` upstream.
class _StubGlasspaneMount implements GlasspaneMount {
  @override
  Object ensureHost() {
    throw UnsupportedError('GlasspaneMount is web-only.');
  }

  @override
  void clearHost() {
    // No-op on non-web targets.
  }
}

/// Returns the non-web stub implementation of [GlasspaneMount].
GlasspaneMount createGlasspaneMount() => _StubGlasspaneMount();
