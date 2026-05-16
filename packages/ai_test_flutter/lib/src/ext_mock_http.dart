import 'dart:convert';
import 'dart:developer' as developer;

import 'ai_test_http_interceptor.dart';
import 'v3_register.dart';

// ---------------------------------------------------------------------------
// VM Service extension handler — ext.aitest.mock_http
// ---------------------------------------------------------------------------

/// Handler for the `ext.aitest.mock_http` VM Service extension.
///
/// Registers a single mock-HTTP rule against [AiTestHttpInterceptor] so the
/// LLM agent can short-circuit a request URL without hitting the network.
///
/// VM Service extension params are always `Map<String, String>` (every value
/// arrives as a JSON string), so [status] is parsed via [int.tryParse] and
/// [headers] is parsed via [jsonDecode] when supplied. Missing or malformed
/// required params return [developer.ServiceExtensionResponse.extensionError]
/// rather than throwing — VM Service handlers must always return a response.
///
/// ## Params
///
/// - `pattern` (required, String) — URL substring or regex pattern.
/// - `status` (required, String → int) — HTTP status code (e.g. `'200'`).
/// - `body` (optional, String, default `''`) — raw response body.
/// - `contentType` (optional, String) — sets `content-type` response header.
/// - `headers` (optional, JSON-encoded `Map<String, String>`) — extra headers.
///
/// ## Response
///
/// ```json
/// { "ok": true, "pattern": "/monitors" }
/// ```
///
/// ## Errors
///
/// - Missing `pattern` or `status` → `extensionError` with a descriptive message.
/// - Malformed `status` (not parseable as int) → `extensionError`.
/// - Malformed `headers` JSON → `extensionError`.
///
/// ## Hot-restart
///
/// Mock rules live in a static [List] inside [AiTestHttpInterceptor] and reset
/// when the Dart isolate restarts (`main()` re-runs). The agent must re-issue
/// `ext.aitest.mock_http` after every hot-restart.
Future<developer.ServiceExtensionResponse> aiTestMockHttpHandler(
  String method,
  Map<String, String> params,
) async {
  try {
    // 1. Validate required string params before any parsing.
    final String? pattern = params['pattern'];
    if (pattern == null || pattern.isEmpty) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        '[ai-test-v3] ext.aitest.mock_http: missing required param "pattern"',
      );
    }

    final String? statusRaw = params['status'];
    if (statusRaw == null || statusRaw.isEmpty) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        '[ai-test-v3] ext.aitest.mock_http: missing required param "status"',
      );
    }

    // 2. Parse the status code. VM Service params arrive as strings so int
    //    coercion happens here and surfaces as an extensionError on failure.
    final int? status = int.tryParse(statusRaw);
    if (status == null) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        '[ai-test-v3] ext.aitest.mock_http: "status" must be an integer, '
        'got "$statusRaw"',
      );
    }

    // 3. Decode optional headers map. JSON is the wire format because the VM
    //    Service params Map<String,String> cannot carry nested structures.
    Map<String, String>? headers;
    final String? headersRaw = params['headers'];
    if (headersRaw != null && headersRaw.isNotEmpty) {
      try {
        final dynamic decoded = jsonDecode(headersRaw);
        if (decoded is! Map) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.extensionError,
            '[ai-test-v3] ext.aitest.mock_http: "headers" must decode to a '
            'JSON object, got ${decoded.runtimeType}',
          );
        }
        headers = <String, String>{
          for (final MapEntry<dynamic, dynamic> entry in decoded.entries)
            entry.key.toString(): entry.value.toString(),
        };
      } on FormatException catch (e) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          '[ai-test-v3] ext.aitest.mock_http: "headers" is not valid JSON: $e',
        );
      }
    }

    // 4. Build the rule map in the shape expected by addMockRule and register.
    final Map<String, dynamic> rule = <String, dynamic>{
      'pattern': pattern,
      'status': status,
      'body': params['body'] ?? '',
      if (params['contentType'] != null) 'contentType': params['contentType'],
      if (headers != null) 'headers': headers,
    };
    AiTestHttpInterceptor.addMockRule(rule);

    return developer.ServiceExtensionResponse.result(
      jsonEncode(<String, dynamic>{
        'ok': true,
        'pattern': pattern,
      }),
    );
  } catch (e, stackTrace) {
    developer.log(
      '[ai-test-v3] ext.aitest.mock_http error: $e\n$stackTrace',
      name: 'ai-test',
    );
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      e.toString(),
    );
  }
}

// ---------------------------------------------------------------------------
// Self-registration entry point
// ---------------------------------------------------------------------------

/// Registers `ext.aitest.mock_http` as a VM Service extension.
///
/// Idempotent: routes through [registerExtensionIdempotent], which catches the
/// [ArgumentError] thrown by [developer.registerExtension] on duplicate
/// registration (hot-restart safety — per V3 plan Stage 3 D12).
///
/// Called from `extensions.dart#registerAllAiTestExtensions()` once the Step
/// 14b aggregator lands. May also be called standalone in tests.
void registerMockHttpExtension() {
  registerExtensionIdempotent('ext.aitest.mock_http', aiTestMockHttpHandler);
}
