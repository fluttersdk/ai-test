import 'metrics.dart';

/// No-op JS publish used on non-web targets (VM, mobile, desktop).
///
/// Selected by the conditional import in `metrics.dart` whenever
/// `dart.library.js_interop` is unavailable. The body is intentionally
/// empty — the VM test runner never needs to write to a JS global.
void publishMetricsSnapshot(MetricsSnapshot snap) {
  // No-op: JS globals are unavailable on non-web targets.
}

/// No-op refresh-hook installer used on non-web targets.
///
/// On web this installs `window.__aiTestRefreshMetrics`; on VM/mobile/desktop
/// there is no JS global surface so the call is silently ignored.
void installRefreshHook(MetricsSnapshot Function() snapshotProvider) {
  // No-op: JS globals are unavailable on non-web targets.
}
