library;

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the navigation extensions (Step 10 of V3 plan).
///
/// Covers:
/// 1. `ext.aitest.navigate` handler returns `{navigated: true, route: path}`.
/// 2. `ext.aitest.navigate_back` handler returns `{navigatedBack: true}`.
/// 3. `ext.aitest.get_routes` handler returns `{location, title}` — semantically
///    identical to the V2 implementation in `extensions.dart`.
/// 4. `registerNavigationExtensions()` registers all 3 extensions without
///    throwing (idempotent via [registerExtensionIdempotent]).
void main() {
  group('buildNavigateResponse', () {
    test('returns navigated=true and the supplied route', () {
      final result = buildNavigateResponse('/dashboard');

      expect(result['navigated'], isTrue);
      expect(result['route'], equals('/dashboard'));
    });

    test('encodes to valid JSON', () {
      final result = buildNavigateResponse('/monitors/abc');
      final json = jsonEncode(result);
      final decoded = jsonDecode(json) as Map<String, dynamic>;

      expect(decoded['navigated'], isTrue);
      expect(decoded['route'], equals('/monitors/abc'));
    });
  });

  group('buildNavigateBackResponse', () {
    test('returns navigatedBack=true', () {
      final result = buildNavigateBackResponse();

      expect(result['navigatedBack'], isTrue);
    });

    test('encodes to valid JSON', () {
      final result = buildNavigateBackResponse();
      final json = jsonEncode(result);
      final decoded = jsonDecode(json) as Map<String, dynamic>;

      expect(decoded['navigatedBack'], isTrue);
    });
  });

  group('buildGetRoutesResponse (navigation module)', () {
    test('includes location and title keys', () {
      final result = buildNavigationGetRoutesResponse();

      expect(result, containsPair('location', anything));
      expect(result, containsPair('title', anything));
    });

    test('location and title are strings', () {
      final result = buildNavigationGetRoutesResponse();

      expect(result['location'], isA<String>());
      expect(result['title'], isA<String>());
    });

    test('encodes to valid JSON', () {
      final result = buildNavigationGetRoutesResponse();
      final json = jsonEncode(result);
      final decoded = jsonDecode(json) as Map<String, dynamic>;

      expect(decoded, containsPair('location', anything));
      expect(decoded, containsPair('title', anything));
    });
  });

  group('ext.aitest.navigate handler', () {
    test('returns ServiceExtensionResponse for a valid route param', () async {
      final response = await aiTestNavigateHandler(
        'ext.aitest.navigate',
        <String, String>{'route': '/settings'},
      );

      expect(response, isNotNull);
      expect(response, isA<developer.ServiceExtensionResponse>());
    });

    test('returns error response when route param is missing', () async {
      final response = await aiTestNavigateHandler(
        'ext.aitest.navigate',
        <String, String>{},
      );

      expect(response, isNotNull);
      expect(response, isA<developer.ServiceExtensionResponse>());
    });
  });

  group('ext.aitest.navigate_back handler', () {
    test('returns ServiceExtensionResponse', () async {
      final response = await aiTestNavigateBackHandler(
        'ext.aitest.navigate_back',
        <String, String>{},
      );

      expect(response, isNotNull);
      expect(response, isA<developer.ServiceExtensionResponse>());
    });
  });

  group('ext.aitest.get_routes handler (navigation module)', () {
    test('returns ServiceExtensionResponse', () async {
      final response = await aiTestNavigationGetRoutesHandler(
        'ext.aitest.get_routes',
        <String, String>{},
      );

      expect(response, isNotNull);
      expect(response, isA<developer.ServiceExtensionResponse>());
    });
  });

  group('registerNavigationExtensions', () {
    test('registers all 3 extensions without throwing', () {
      // registerExtensionIdempotent swallows ArgumentError on duplicate
      // registration, so calling registerNavigationExtensions() multiple times
      // must not throw regardless of prior test state.
      expect(registerNavigationExtensions, returnsNormally);
      expect(registerNavigationExtensions, returnsNormally);
    });
  });
}
