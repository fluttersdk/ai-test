library;

import 'dart:convert';

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ext.aitest.getRoutes extension', () {
    test('buildGetRoutesResponse includes location and title keys', () {
      // Call the internal helper that builds the response.
      // MagicRouter is initialized by Flutter test framework.
      final response = buildGetRoutesResponse();

      // Verify both required keys are present.
      expect(response, containsPair('location', anything));
      expect(response, containsPair('title', anything));

      // Verify the values are strings.
      expect(response['location'], isA<String>());
      expect(response['title'], isA<String>());
    });

    test('buildGetRoutesResponse encodes to valid JSON', () {
      final response = buildGetRoutesResponse();

      // Verify it can be JSON-encoded.
      final jsonString = jsonEncode(response);
      expect(jsonString, isNotEmpty);

      // Verify the JSON can be decoded back.
      final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
      expect(decoded, containsPair('location', anything));
      expect(decoded, containsPair('title', anything));
    });

    test('aiTestGetRoutesHandler returns ServiceExtensionResponse', () async {
      // Invoke the handler directly.
      final response = await aiTestGetRoutesHandler(
        'ext.aitest.getRoutes',
        <String, String>{},
      );

      // Verify the handler returned a response object (not null).
      expect(response, isNotNull);
    });
  });
}
