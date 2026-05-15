import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:magic/magic.dart';

/// Tracks whether extensions have been registered to prevent double-registration
/// on hot-reload.
bool _registered = false;

/// Builds the response JSON for the `ext.aitest.getRoutes` extension.
///
/// This is extracted as a separate function for testability.
///
/// Returns a map with:
/// - `location`: current GoRouter location (via MagicRouter)
/// - `title`: current page title (via MagicRoute facade)
///
/// Throws on any error accessing routing state.
@visibleForTesting
Map<String, dynamic> buildGetRoutesResponse() => <String, dynamic>{
      'location': MagicRouter.instance.currentLocation ?? '',
      'title': MagicRoute.currentTitle ?? '',
    };

/// Handler for the `ext.aitest.getRoutes` VM Service extension.
///
/// Returns the current GoRouter location and page title as JSON:
/// `{ "location": "/current/path", "title": "Page Title" }`.
///
/// Must be a top-level function to be callable as a Dart VM Service RPC handler.
Future<developer.ServiceExtensionResponse> aiTestGetRoutesHandler(
  String method,
  Map<String, String> params,
) async {
  try {
    final response = buildGetRoutesResponse();

    return developer.ServiceExtensionResponse.result(
      jsonEncode(response),
    );
  } catch (e) {
    return developer.ServiceExtensionResponse.error(-1, e.toString());
  }
}

/// Registers the `ext.aitest.getRoutes` VM Service extension.
///
/// This function must be called during app initialization when debug mode
/// is active. It is a no-op in release mode (gated by [kDebugMode]).
///
/// Idempotent: calls after the first one are silently ignored to prevent
/// double-registration on hot-reload.
///
/// The registered extension is callable by VM Service clients (e.g., DevTools,
/// ai_test_node MCP server) via JSON-RPC:
///
/// ```json
/// {
///   "jsonrpc": "2.0",
///   "method": "ext.aitest.getRoutes",
///   "params": {},
///   "id": 1
/// }
/// ```
///
/// Response (success):
/// ```json
/// {
///   "location": "/auth/login",
///   "title": "Login"
/// }
/// ```
void registerAiTestExtensions() {
  // Gate: only register in debug mode. Release builds tree-shake this call.
  if (!kDebugMode) {
    return;
  }

  // Idempotent: prevent double-registration on hot-reload.
  if (_registered) {
    return;
  }

  _registered = true;

  // Register the `ext.aitest.getRoutes` extension.
  developer.registerExtension(
    'ext.aitest.getRoutes',
    aiTestGetRoutesHandler,
  );
}
