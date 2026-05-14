import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';

import 'helpers/glasspane_test_probe_stub.dart'
    if (dart.library.js_interop) 'helpers/glasspane_test_probe_web.dart';

void main() {
  group('GlasspaneMount factory', () {
    test('createGlasspaneMount() returns a GlasspaneMount instance', () {
      final mount = createGlasspaneMount();

      expect(mount, isA<GlasspaneMount>());
    });

    test(
      'stub ensureHost() throws UnsupportedError on non-web targets',
      () {
        if (kIsWeb) return;

        final mount = createGlasspaneMount();

        expect(mount.ensureHost, throwsA(isA<UnsupportedError>()));
      },
    );
  });

  group('GlasspaneMount web behaviour', () {
    test(
      'ensureHost() returns a non-null Object inside flt-glass-pane.shadowRoot',
      () {
        if (!kIsWeb) return;

        final mount = createGlasspaneMount();
        final host = mount.ensureHost();

        expect(host, isNotNull);
        expect(hostIsInsideGlassPaneShadowRoot(host), isTrue);

        // Idempotency: a second call must not append a duplicate node.
        final hostAgain = mount.ensureHost();
        expect(identical(host, hostAgain), isTrue);

        // clearHost() removes the appended host so subsequent test runs
        // start from a clean glass-pane.
        mount.clearHost();
        expect(hostIsInsideGlassPaneShadowRoot(host), isFalse);
      },
    );
  });
}
