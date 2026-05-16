library;

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Wave 3 aggregator (registerAllAiTestExtensions)', () {
    test('registerAllAiTestExtensions can be called without throwing', () {
      // The aggregator calls each register<X>Extension(s)() function in sequence.
      // Each module uses registerExtensionIdempotent internally, so calling the
      // aggregator multiple times is safe.
      expect(
        () => registerAllAiTestExtensions(),
        returnsNormally,
      );
    });

    test('resetForTesting can be called without throwing', () {
      // Reset helper for testing scenarios.
      expect(
        () => resetForTesting(),
        returnsNormally,
      );
    });
  });
}
