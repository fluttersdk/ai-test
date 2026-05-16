import 'dart:convert';
import 'dart:developer' as developer;

import 'package:logging/logging.dart' show Level;

import 'ai_test_http_interceptor.dart';
import 'ai_test_log_sink.dart';
import 'v3_register.dart';

/// Registers the `ext.aitest.network_requests` and `ext.aitest.console_messages`
/// VM Service extensions.
///
/// Call from the V3 extensions aggregator (`extensions.dart#registerAllAiTestExtensions`)
/// once during plugin install. This function is idempotent: every underlying
/// [registerExtensionIdempotent] call swallows ArgumentError on hot-restart.
///
/// Neither extension triggers outbound HTTP or logging calls — they only read
/// from the ring buffers managed by [AiTestHttpInterceptor] and [AiTestLogSink].
void registerNetworkConsoleExtensions() {
  registerExtensionIdempotent(
    'ext.aitest.network_requests',
    aiTestNetworkRequestsHandler,
  );
  registerExtensionIdempotent(
    'ext.aitest.console_messages',
    aiTestConsoleMessagesHandler,
  );
}

// ---------------------------------------------------------------------------
// ext.aitest.network_requests
// ---------------------------------------------------------------------------

/// Handler for the `ext.aitest.network_requests` VM Service extension.
///
/// Returns recent HTTP request/response records captured by [AiTestHttpInterceptor].
///
/// Supported query params:
/// - `limit` (int, optional): cap the number of returned entries to the N most
///   recent. Defaults to all buffered records (up to 50).
/// - `filter` (String, optional): URL substring; only entries whose `url` field
///   contains this string are included.
///
/// Response shape:
/// ```json
/// { "requests": [ { "url": "...", "method": "GET", "statusCode": 200,
///                   "durationMs": 42, "isError": false,
///                   "timestamp": "2026-05-16T00:00:00.000Z" }, ... ] }
/// ```
///
/// All values are JSON-serializable. DateTime values are already ISO-8601
/// strings in the ring-buffer entries (coerced at capture time by the
/// interceptor's `_buildEntry` method).
Future<developer.ServiceExtensionResponse> aiTestNetworkRequestsHandler(
  String method,
  Map<String, String> params,
) async {
  try {
    // 1. Parse optional limit — ignore non-integer strings.
    final int? limit = _parseInt(params['limit']);

    // 2. Fetch the buffered slice.
    final List<Map<String, dynamic>> entries =
        AiTestHttpInterceptor.recentRequests(limit: limit);

    // 3. Apply optional URL substring filter.
    final String? filter = params['filter'];
    final List<Map<String, dynamic>> filtered = (filter != null &&
            filter.isNotEmpty)
        ? entries.where((e) => (e['url'] as String).contains(filter)).toList()
        : entries;

    // 4. Return as JSON — entries are already JSON-serializable maps.
    return developer.ServiceExtensionResponse.result(
      jsonEncode(<String, dynamic>{'requests': filtered}),
    );
  } catch (e) {
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      e.toString(),
    );
  }
}

// ---------------------------------------------------------------------------
// ext.aitest.console_messages
// ---------------------------------------------------------------------------

/// Handler for the `ext.aitest.console_messages` VM Service extension.
///
/// Returns recent log records captured by [AiTestLogSink].
///
/// Supported query params:
/// - `limit` (int, optional): cap the number of returned entries to the N most
///   recent. Defaults to all buffered records (up to 100).
/// - `level` (String, optional): minimum log level name. Case-insensitive.
///   Recognised names: `all`, `finest`, `finer`, `fine`, `config`, `info`,
///   `warning`, `severe`, `shout`. Unknown names are silently ignored (all
///   records returned).
///
/// Level name to [Level] mapping:
/// | name     | Level value |
/// |----------|-------------|
/// | all      | 0           |
/// | finest   | 300         |
/// | finer    | 400         |
/// | fine     | 500         |
/// | config   | 700         |
/// | info     | 800         |
/// | warning  | 900         |
/// | error    | 1000 (SEVERE) |
/// | severe   | 1000        |
/// | shout    | 1200        |
///
/// Response shape:
/// ```json
/// { "messages": [ { "level": "INFO", "levelValue": 800,
///                   "message": "...", "loggerName": "ai.test",
///                   "time": "2026-05-16T00:00:00.000Z",
///                   "error": null, "stackTrace": null }, ... ] }
/// ```
Future<developer.ServiceExtensionResponse> aiTestConsoleMessagesHandler(
  String method,
  Map<String, String> params,
) async {
  try {
    // 1. Parse optional limit.
    final int? limit = _parseInt(params['limit']);

    // 2. Resolve optional level name to a numeric threshold.
    final int? minLevel = _resolveLevelName(params['level']);

    // 3. Fetch filtered slice from the ring buffer.
    final List<Map<String, dynamic>> entries =
        AiTestLogSink.recentLogs(limit: limit, minLevel: minLevel);

    // 4. Return as JSON — entries are already JSON-serializable maps.
    return developer.ServiceExtensionResponse.result(
      jsonEncode(<String, dynamic>{'messages': entries}),
    );
  } catch (e) {
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      e.toString(),
    );
  }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Parses [raw] as a positive integer. Returns null if [raw] is null or not
/// a valid integer — callers treat null as "no limit".
int? _parseInt(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return int.tryParse(raw);
}

/// Maps a level name string to its [Level.value] integer threshold.
///
/// Returns null when [name] is null, blank, or unrecognised — callers treat
/// null as "no minimum level filter".
///
/// The string `'error'` is an alias for `'severe'` (Level.SEVERE = 1000) so
/// that MCP tool users can use conventional web-console vocabulary.
int? _resolveLevelName(String? name) {
  if (name == null || name.isEmpty) return null;

  return switch (name.toLowerCase()) {
    'all' => Level.ALL.value,
    'finest' => Level.FINEST.value,
    'finer' => Level.FINER.value,
    'fine' => Level.FINE.value,
    'config' => Level.CONFIG.value,
    'info' => Level.INFO.value,
    'warning' => Level.WARNING.value,
    'error' => Level.SEVERE.value, // web-console alias for severe
    'severe' => Level.SEVERE.value,
    'shout' => Level.SHOUT.value,
    _ => null, // unknown name — no filter applied
  };
}
