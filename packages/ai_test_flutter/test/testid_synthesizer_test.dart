import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TestidSynthesizer', () {
    testWidgets(
      'WFormInput controller-attached produces input.<fieldName>',
      (tester) async {
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        final element = tester.element(find.byType(SizedBox));
        final synthesizer = TestidSynthesizer();

        final result = synthesizer.synthesize(
          element,
          widgetTypeName: 'WFormInput',
          formFieldName: 'email',
        );

        expect(result, equals('input.email'));
      },
    );

    testWidgets(
      'WButton with text child produces button.<snake_case_text>',
      (tester) async {
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        final element = tester.element(find.byType(SizedBox));
        final synthesizer = TestidSynthesizer();

        final result = synthesizer.synthesize(
          element,
          widgetTypeName: 'WButton',
          extractedText: 'Sign In',
        );

        expect(result, equals('button.sign_in'));
      },
    );

    testWidgets(
      'WAnchor with text child produces link.<snake_case_text>',
      (tester) async {
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        final element = tester.element(find.byType(SizedBox));
        final synthesizer = TestidSynthesizer();

        final result = synthesizer.synthesize(
          element,
          widgetTypeName: 'WAnchor',
          extractedText: 'Forgot password?',
        );

        expect(result, equals('link.forgot_password'));
      },
    );

    testWidgets(
      'fallback uses runtimeType + position-hash for unrecognized widgets',
      (tester) async {
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        final element = tester.element(find.byType(SizedBox));
        final synthesizer = TestidSynthesizer();

        final result = synthesizer.synthesize(
          element,
          widgetTypeName: 'SomeUnknownWidget',
        );

        expect(result, startsWith('unknown.someunknownwidget.'));
      },
    );

    testWidgets(
      'explicit Key always wins over synthesis',
      (tester) async {
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        final element = tester.element(find.byType(SizedBox));
        final synthesizer = TestidSynthesizer();

        final result = synthesizer.synthesize(
          element,
          widgetTypeName: 'WButton',
          extractedText: 'Sign In',
          key: const ValueKey<String>('foo'),
        );

        expect(result, equals('foo'));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Snake-case edge cases — tested in isolation via a public test hook.
  // ---------------------------------------------------------------------------

  group('TestidSynthesizer._snakeCase edge cases', () {
    test(
        "apostrophe is stripped (not converted to underscore): Don't have account?",
        () {
      expect(
        TestidSynthesizer.snakeCaseForTesting("Don't have account?"),
        equals('dont_have_account'),
      );
    });

    test('multiple spaces collapse to single underscore', () {
      expect(
        TestidSynthesizer.snakeCaseForTesting('Sign   In'),
        equals('sign_in'),
      );
    });

    test('leading and trailing whitespace is trimmed', () {
      expect(
        TestidSynthesizer.snakeCaseForTesting('  Email  '),
        equals('email'),
      );
    });

    test('punctuation is stripped', () {
      expect(
        TestidSynthesizer.snakeCaseForTesting('Hello, World!'),
        equals('hello_world'),
      );
    });
  });
}
