import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Spy host that records whether activate() was called.
// ---------------------------------------------------------------------------

class _SpyHost implements AiTestHost {
  int activationCount = 0;

  @override
  void activate() => activationCount++;
}

void main() {
  // Reset static state between tests so they are independent.
  setUp(AiTestBinding.resetForTesting);

  test(
    'ensureInitialized is no-op when kDebugMode is false',
    () {
      final host = _SpyHost();

      AiTestBinding.ensureInitialized(
        overrideDebugMode: false,
        overrideDartDefineValue: '1',
        host: host,
      );

      expect(host.activationCount, equals(0));
    },
  );

  test(
    'ensureInitialized installs projection when dart-define equivalent is "1"',
    () {
      final host = _SpyHost();

      AiTestBinding.ensureInitialized(
        overrideDebugMode: true,
        overrideDartDefineValue: '1',
        host: host,
      );

      expect(host.activationCount, equals(1));
    },
  );

  test(
    'ensureInitialized installs projection when ?aiTest=1 query param is present',
    () {
      final host = _SpyHost();

      AiTestBinding.ensureInitialized(
        overrideDebugMode: true,
        overrideDartDefineValue: '0',
        overrideUri: Uri.parse('https://example.com/?aiTest=1'),
        host: host,
      );

      expect(host.activationCount, equals(1));
    },
  );
}
