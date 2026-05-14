import 'metrics.dart';

/// No-op JS publish used on non-web targets (VM, mobile, desktop).
///
/// Selected by the conditional import in `metrics.dart` whenever
/// `dart.library.js_interop` is unavailable. The body is intentionally
/// empty — the VM test runner never needs to write to a JS global.
void publishMetricsSnapshot(MetricsSnapshot snap) {
  // No-op: JS globals are unavailable on non-web targets.
}
