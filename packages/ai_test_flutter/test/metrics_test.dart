import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProjectionMetrics', () {
    test('record() appends a sample', () {
      final metrics = ProjectionMetrics(publishToJs: false);

      metrics.record(500);

      final snap = metrics.snapshot();
      expect(snap.count, equals(1));
      expect(snap.avg, equals(500.0));
    });

    test('snapshot() returns avg + p50 + p95 + p99', () {
      final metrics = ProjectionMetrics(publishToJs: false);

      // Known sequence: 1..10. At N=10:
      //   sorted: [1,2,3,4,5,6,7,8,9,10]
      //   avg = 5.5
      //   p50 index = floor(10*0.50) - 1 = 4  → 5
      //   p95 index = floor(10*0.95) - 1 = 8  → 9  ... re-check with ceil:
      //   Using ceil((N * pct) / 100) - 1 for nearest-rank:
      //     p50 → ceil(10*50/100)-1 = ceil(5)-1 = 4 → value 5
      //     p95 → ceil(10*95/100)-1 = ceil(9.5)-1 = 9 → value 10
      //     p99 → ceil(10*99/100)-1 = ceil(9.9)-1 = 9 → value 10
      for (var i = 1; i <= 10; i++) {
        metrics.record(i);
      }

      final snap = metrics.snapshot();
      expect(snap.count, equals(10));
      expect(snap.avg, closeTo(5.5, 0.001));
      expect(snap.p50, equals(5));
      expect(snap.p95, equals(10));
      expect(snap.p99, equals(10));
    });

    test('reset() clears samples', () {
      final metrics = ProjectionMetrics(publishToJs: false);
      metrics.record(100);
      metrics.record(200);

      metrics.reset();

      final snap = metrics.snapshot();
      expect(snap.count, equals(0));
    });

    test('samples are bounded to lastN entries (default 600)', () {
      final metrics = ProjectionMetrics(publishToJs: false);

      // Record 650 samples; only the last 600 should be retained.
      for (var i = 1; i <= 650; i++) {
        metrics.record(i);
      }

      final snap = metrics.snapshot();
      expect(snap.count, equals(600));
      // The last 600 samples are 51..650; avg = (51+650)/2 = 350.5.
      expect(snap.avg, closeTo(350.5, 0.001));
    });

    test('snapshot() handles N<5 sample case gracefully', () {
      final metrics = ProjectionMetrics(publishToJs: false);

      // Empty — count == 0 is the documented "N<5" sentinel.
      final empty = metrics.snapshot();
      expect(empty.count, equals(0));

      // Single sample — all percentiles equal the single value.
      metrics.record(42);
      final single = metrics.snapshot();
      expect(single.count, equals(1));
      expect(single.p50, equals(42));
      expect(single.p95, equals(42));
      expect(single.p99, equals(42));
    });

    test('record() with maxSamples=3 evicts FIFO via ListQueue', () {
      final metrics = ProjectionMetrics(publishToJs: false, maxSamples: 3);

      // Record 4 samples into a ring buffer of capacity 3.
      // After the 4th record the first sample (10) must be evicted.
      metrics.record(10);
      metrics.record(20);
      metrics.record(30);
      metrics.record(40);

      final snap = metrics.snapshot();

      // Only 3 samples are retained.
      expect(snap.count, equals(3));

      // The retained samples are [20, 30, 40]; avg = 30.0.
      // If FIFO eviction is wrong (e.g. last element removed instead of first),
      // the avg would be (10 + 20 + 30) / 3 = 20.0.
      expect(snap.avg, closeTo(30.0, 0.001));
    });

    test('snapshot() publishes to JS only every Nth frame (default 30)', () {
      // Fake publish function captures every call so we can assert the cadence
      // without touching any real JS global.
      final List<MetricsSnapshot> published = <MetricsSnapshot>[];
      void fakePublish(MetricsSnapshot snap) => published.add(snap);

      final metrics = ProjectionMetrics(
        publishToJs: true,
        publishFnForTesting: fakePublish,
      );

      // Record a baseline sample so snapshots are non-empty.
      metrics.record(100);

      // Frames 1..29 — counter advances but threshold (30) not yet reached.
      for (var i = 1; i < 30; i++) {
        metrics.snapshot();
      }
      expect(published, isEmpty, reason: 'no publish before frame 30');

      // Frame 30 — threshold reached; publish must fire.
      metrics.snapshot();
      expect(published.length, equals(1), reason: 'publish fires on frame 30');

      // Frames 31..59 — second window, counter resets, no publish yet.
      for (var i = 31; i < 60; i++) {
        metrics.snapshot();
      }
      expect(published.length, equals(1),
          reason: 'no second publish before frame 60');

      // Frame 60 — second threshold; publish fires again.
      metrics.snapshot();
      expect(published.length, equals(2), reason: 'publish fires on frame 60');

      // Frames 61..89.
      for (var i = 61; i < 90; i++) {
        metrics.snapshot();
      }
      expect(published.length, equals(2),
          reason: 'no third publish before frame 90');

      // Frame 90 — third threshold.
      metrics.snapshot();
      expect(published.length, equals(3), reason: 'publish fires on frame 90');

      // Spot-check: frames 1, 5, 29 were NOT publish frames (tested via counts above).
    });
  });
}
