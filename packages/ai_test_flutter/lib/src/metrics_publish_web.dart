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
