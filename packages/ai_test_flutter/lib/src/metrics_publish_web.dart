import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'metrics.dart';

/// Writes [snap] to `window.__aiTestMetrics` as a plain JS object.
///
/// Selected by the conditional import in `metrics.dart` when
/// `dart.library.js_interop` is available (web / dart2js / dart2wasm).
///
/// Only the five scalar fields (`avg`, `p50`, `p95`, `p99`, `count`) are
/// written. The raw sample list is never exported — it could grow to
/// megabyte scale at 60fps.
void publishMetricsSnapshot(MetricsSnapshot snap) {
  globalContext['__aiTestMetrics'] = <String, Object?>{
    'avg': snap.avg,
    'p50': snap.p50,
    'p95': snap.p95,
    'p99': snap.p99,
    'count': snap.count,
  }.jsify()!;
}

/// Installs `window.__aiTestRefreshMetrics` as a callable JS function.
///
/// When Playwright calls `window.__aiTestRefreshMetrics()`, it synchronously
/// computes the latest [MetricsSnapshot] via [snapshotProvider] and writes it
/// to `window.__aiTestMetrics`. This bypasses the 30-frame throttle so specs
/// always read fresh data on demand.
///
/// Call this from `Projection.activate()` after the [ProjectionMetrics]
/// instance is ready, passing a closure that invokes its `snapshot()` method.
void installRefreshHook(MetricsSnapshot Function() snapshotProvider) {
  globalContext['__aiTestRefreshMetrics'] = (() {
    final MetricsSnapshot snap = snapshotProvider();
    publishMetricsSnapshot(snap);
  }).toJS;
}
