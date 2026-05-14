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
  });
}
