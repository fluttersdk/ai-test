import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RoleResolver', () {
    test('WButton resolves to button role', () {
      final resolver = RoleResolver();

      expect(resolver.resolve('WButton'), equals('button'));
    });

    test('WInput resolves to textbox role', () {
      final resolver = RoleResolver();

      expect(resolver.resolve('WInput'), equals('textbox'));
    });

    test('WAnchor standalone resolves to button role', () {
      final resolver = RoleResolver();

      expect(resolver.resolve('WAnchor'), equals('button'));
    });

    test('WIcon resolves to image role', () {
      final resolver = RoleResolver();

      expect(resolver.resolve('WIcon'), equals('image'));
    });

    test('unknown widget type resolves to none', () {
      final resolver = RoleResolver();

      expect(resolver.resolve('SomeUnknownWidget'), equals('none'));
    });

    test('consumer can register a custom resolver', () {
      final resolver = RoleResolver();
      resolver.register('MyCustomWidget', 'dialog');

      expect(resolver.resolve('MyCustomWidget'), equals('dialog'));
    });
  });
}
