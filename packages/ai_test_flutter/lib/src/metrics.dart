import 'package:flutter/foundation.dart';

import 'metrics_publish_stub.dart'
    if (dart.library.js_interop) 'metrics_publish_web.dart';

// ---------------------------------------------------------------------------
// MetricsSnapshot — immutable value object
// ---------------------------------------------------------------------------

/// Immutable snapshot of per-frame Shadow DOM projection costs.
///
/// All duration values are in **microseconds**.
///
/// When [count] is `0` (no samples recorded), all percentile fields are `0`
/// and [avg] is `0.0`. Callers must guard on [count] before interpreting
/// percentile values — this is the documented "no-samples" sentinel.
@immutable
class MetricsSnapshot {
  /// The mean projection cost in microseconds.
  final double avg;

  /// The 50th-percentile projection cost in microseconds.
  final int p50;

  /// The 95th-percentile projection cost in microseconds.
  final int p95;

  /// The 99th-percentile projection cost in microseconds.
  final int p99;

  /// The number of samples that contributed to this snapshot.
  final int count;

  const MetricsSnapshot({
    required this.avg,
    required this.p50,
    required this.p95,
    required this.p99,
    required this.count,
  });
}

// ---------------------------------------------------------------------------
// ProjectionMetrics — ring-buffer recorder
// ---------------------------------------------------------------------------

/// Records per-frame Shadow DOM projection costs and exposes percentile
/// snapshots for analysis and optional JS consumption.
///
/// ## JS exposure
///
/// When [publishToJs] is `true` (the default) AND the app is running on web
/// ([kIsWeb]), each [snapshot] call writes the result to
/// `window.__aiTestMetrics` as a plain JS object with five numeric fields:
/// `avg`, `p50`, `p95`, `p99`, `count`. The raw sample list is never
/// exported — it could grow to megabyte scale at 60fps.
///
/// Pass `publishToJs: false` in unit tests so the VM target does not attempt
/// a web-only JS write.
///
/// ## Ring-buffer semantics
///
/// The internal sample list is bounded to [maxSamples] entries. When capacity
/// is exceeded, the oldest sample is evicted (FIFO). The default of `600`
/// covers 10 seconds of 60fps projection without unbounded memory growth.
///
/// ## Percentile algorithm
///
/// Uses the nearest-rank method:
/// `rank = ceil(N * pct / 100)`, clamped to `[1, N]`, then reads
/// `sortedSamples[rank - 1]`. Matches common monitoring tooling (e.g.
/// Prometheus histogram_quantile nearest-rank approximation).
class ProjectionMetrics {
  /// Maximum number of samples retained at any time.
  ///
  /// Defaults to `600` (10 seconds at 60fps).
  final int maxSamples;

  /// Whether to publish each snapshot to `window.__aiTestMetrics` on web.
  ///
  /// Set to `false` in unit tests to avoid VM-target JS write attempts.
  final bool publishToJs;

  final List<int> _samples = [];

  /// Creates a [ProjectionMetrics] instance.
  ///
  /// [maxSamples] defaults to `600`. [publishToJs] defaults to `true`; pass
  /// `false` in unit tests.
  ProjectionMetrics({
    this.maxSamples = 600,
    this.publishToJs = true,
  });

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  /// Records a single projection cost sample in [microseconds].
  ///
  /// When [maxSamples] is reached, the oldest sample is removed first (FIFO
  /// ring-buffer) before the new sample is appended.
  void record(int microseconds) {
    if (_samples.length >= maxSamples) {
      _samples.removeAt(0);
    }
    _samples.add(microseconds);
  }

  /// Returns a percentile snapshot of all recorded samples.
  ///
  /// When [count] is `0` (no samples), all percentile fields are `0` and
  /// [avg] is `0.0` — guard on [count] before interpreting these values.
  ///
  /// When [publishToJs] is `true` AND [kIsWeb] is `true`, also writes the
  /// snapshot to `window.__aiTestMetrics`.
  MetricsSnapshot snapshot() {
    final int n = _samples.length;

    if (n == 0) {
      const MetricsSnapshot empty = MetricsSnapshot(
        avg: 0.0,
        p50: 0,
        p95: 0,
        p99: 0,
        count: 0,
      );
      if (publishToJs && kIsWeb) {
        publishMetricsSnapshot(empty);
      }
      return empty;
    }

    // 1. Sort a copy so the original insertion order (ring-buffer) is preserved.
    final List<int> sorted = List<int>.from(_samples)..sort();

    // 2. Compute the arithmetic mean.
    final double avg = sorted.reduce((int a, int b) => a + b) / n;

    // 3. Compute percentiles via nearest-rank: rank = ceil(N * pct / 100).
    final int p50 = _percentile(sorted, n, 50);
    final int p95 = _percentile(sorted, n, 95);
    final int p99 = _percentile(sorted, n, 99);

    final MetricsSnapshot snap = MetricsSnapshot(
      avg: avg,
      p50: p50,
      p95: p95,
      p99: p99,
      count: n,
    );

    // 4. Push to JS global when running on web and opted in.
    if (publishToJs && kIsWeb) {
      publishMetricsSnapshot(snap);
    }

    return snap;
  }

  /// Clears all recorded samples.
  ///
  /// The JS global `window.__aiTestMetrics` is NOT cleared; it retains the
  /// last written snapshot until the next [snapshot] call.
  void reset() {
    _samples.clear();
  }

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  /// Nearest-rank percentile from a pre-sorted list.
  ///
  /// `rank = ceil(n * pct / 100)`, clamped to `[1, n]`, then reads
  /// `sorted[rank - 1]`.
  int _percentile(List<int> sorted, int n, int pct) {
    final int rank = ((n * pct) / 100).ceil().clamp(1, n);
    return sorted[rank - 1];
  }
}
