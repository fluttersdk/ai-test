/// No-op stability publisher for non-web targets.
///
/// Selected by the conditional import in `projection.dart` whenever
/// `dart.library.js_interop` is unavailable (VM, mobile, desktop). The
/// projection itself never runs off web, but the symbol must exist so the
/// VM compile target resolves.
void publishStabilityFlag(bool stable) {
  // No-op: JS globals are unavailable on non-web targets.
}
