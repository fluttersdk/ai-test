import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ai_test_flutter/src/mirror_node.dart';

void main() {
  setUp(() {});

  group('MirrorNode', () {
    final Object fakeHost = Object();
    const Rect rectA = Rect.fromLTWH(0, 0, 100, 50);
    const Rect rectB = Rect.fromLTWH(10, 20, 200, 80);

    MirrorNode makeNode({
      Rect rect = rectA,
      String testid = 'button.submit',
      String? role,
      String? text,
    }) {
      return MirrorNode(
        hostElement: fakeHost,
        lastRect: rect,
        lastTestid: testid,
        lastRole: role,
        lastText: text,
      );
    }

    test('needsUpdate true when rect changes', () {
      final node = makeNode(rect: rectA);
      expect(
        node.needsUpdate(
          newRect: rectB,
          newTestid: 'button.submit',
          newRole: null,
          newText: null,
        ),
        isTrue,
      );
    });

    test('needsUpdate true when testid changes', () {
      final node = makeNode(testid: 'button.submit');
      expect(
        node.needsUpdate(
          newRect: rectA,
          newTestid: 'button.cancel',
          newRole: null,
          newText: null,
        ),
        isTrue,
      );
    });

    test('needsUpdate false when nothing changed', () {
      final node = makeNode(
        rect: rectA,
        testid: 'input.email',
        role: 'textbox',
        text: 'hello',
      );
      expect(
        node.needsUpdate(
          newRect: rectA,
          newTestid: 'input.email',
          newRole: 'textbox',
          newText: 'hello',
        ),
        isFalse,
      );
    });

    test('recordCommitted updates all four fields', () {
      final node = makeNode(
        rect: rectA,
        testid: 'input.email',
        role: null,
        text: null,
      );

      node.recordCommitted(
        rect: rectB,
        testid: 'input.password',
        role: 'textbox',
        text: 'secret',
      );

      expect(node.lastRect, equals(rectB));
      expect(node.lastTestid, equals('input.password'));
      expect(node.lastRole, equals('textbox'));
      expect(node.lastText, equals('secret'));
    });
  });
}
