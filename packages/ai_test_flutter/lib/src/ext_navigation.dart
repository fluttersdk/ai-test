import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:magic/magic.dart';

import 'v3_register.dart';

/// Registers the navigation VM Service extensions for the V3 ai_test plugin.
///
/// Three extensions are registered:
///
/// | Extension                    | Description                                          |
/// |------------------------------|------------------------------------------------------|
/// | `ext.aitest.navigate`        | Navigate to a route via [MagicRoute.to].             |
/// | `ext.aitest.navigate_back`   | Go back via [MagicRoute.back].                       |
/// | `ext.aitest.get_routes`      | Return current location + title (V2-compatible).     |
///
/// Each call goes through [registerExtensionIdempotent] so hot-restart
/// duplicate-registration [ArgumentError]s are swallowed safely.
///
/// Call this once from the Wave 3 aggregator (`extensions.dart`). The module
/// is intentionally self-contained: no shared `extensions.dart` edit is needed
/// per the Step 10 plan note.
void registerNavigationExtensions() {
  registerExtensionIdempotent('ext.aitest.navigate', aiTestNavigateHandler);
  registerExtensionIdempotent(
    'ext.aitest.navigate_back',
    aiTestNavigateBackHandler,
  );
  registerExtensionIdempotent(
    'ext.aitest.get_routes',
    aiTestNavigationGetRoutesHandler,
  );
}

// ---------------------------------------------------------------------------
// Response builders (extracted for testability)
// ---------------------------------------------------------------------------

/// Builds the success payload for `ext.aitest.navigate`.
///
/// Returns a map with:
/// - `navigated`: always `true`
/// - `route`: the requested route path
@visibleForTesting
Map<String, dynamic> buildNavigateResponse(String route) => <String, dynamic>{
      'navigated': true,
      'route': route,
    };

/// Builds the success payload for `ext.aitest.navigate_back`.
///
/// Returns a map with:
/// - `navigatedBack`: always `true`
@visibleForTesting
Map<String, dynamic> buildNavigateBackResponse() => <String, dynamic>{
      'navigatedBack': true,
    };

/// Builds the response payload for `ext.aitest.get_routes`.
///
/// Semantically identical to V2's `buildGetRoutesResponse()` in
/// `extensions.dart` — kept as a separate function in this module so the
/// Step 14b aggregator rewrite can wire both from a single self-registered
/// module without touching the V2 file.
///
/// Returns a map with:
/// - `location`: current GoRouter location (via [MagicRouter])
/// - `title`: current page title (via [MagicRoute.currentTitle])
@visibleForTesting
Map<String, dynamic> buildNavigationGetRoutesResponse() => <String, dynamic>{
      'location': MagicRouter.instance.currentLocation ?? '',
      'title': MagicRoute.currentTitle ?? '',
    };

// ---------------------------------------------------------------------------
// VM Service extension handlers
// ---------------------------------------------------------------------------

/// Handler for `ext.aitest.navigate`.
///
/// Params:
/// - `route` (required): the path to navigate to (e.g. `/dashboard`).
///
/// On success: `{ "navigated": true, "route": "/dashboard" }`.
/// On missing `route` param: returns an extension error response.
///
/// Navigation is performed via [MagicRoute.to], which is context-free and
/// safe to call from any isolate. The extension does NOT await a frame settle
/// because GoRouter navigation is synchronous from the caller's perspective
/// (the router schedules the rebuild internally).
Future<developer.ServiceExtensionResponse> aiTestNavigateHandler(
  String method,
  Map<String, String> params,
) async {
  try {
    final String? route = params['route'];
    if (route == null || route.isEmpty) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        'Missing required param: route',
      );
    }

    // 1. Perform navigation via the Magic facade — context-free, safe from
    //    extension handlers.
    MagicRoute.to(route);

    // 2. Return confirmation so the MCP tool can assert navigation happened.
    return developer.ServiceExtensionResponse.result(
      jsonEncode(buildNavigateResponse(route)),
    );
  } catch (e) {
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      e.toString(),
    );
  }
}

/// Handler for `ext.aitest.navigate_back`.
///
/// Params: none.
///
/// On success: `{ "navigatedBack": true }`.
///
/// Navigation is performed via [MagicRoute.back], which is context-free.
/// Does NOT store or reference [BuildContext] — the Must NOT constraint from
/// the plan prohibits that.
Future<developer.ServiceExtensionResponse> aiTestNavigateBackHandler(
  String method,
  Map<String, String> params,
) async {
  try {
    // 1. Go back via the Magic facade — no BuildContext required.
    MagicRoute.back();

    // 2. Return confirmation.
    return developer.ServiceExtensionResponse.result(
      jsonEncode(buildNavigateBackResponse()),
    );
  } catch (e) {
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      e.toString(),
    );
  }
}

/// Handler for `ext.aitest.get_routes`.
///
/// Params: none.
///
/// On success: `{ "location": "/current/path", "title": "Page Title" }`.
///
/// This is the V3 self-registered equivalent of the V2 `aiTestGetRoutesHandler`
/// in `extensions.dart`. The response shape is identical so existing MCP tool
/// wrappers need no changes.
Future<developer.ServiceExtensionResponse> aiTestNavigationGetRoutesHandler(
  String method,
  Map<String, String> params,
) async {
  try {
    return developer.ServiceExtensionResponse.result(
      jsonEncode(buildNavigationGetRoutesResponse()),
    );
  } catch (e) {
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      e.toString(),
    );
  }
}
