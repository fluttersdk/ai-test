import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;

import 'package:magic/magic.dart';

/// A single mock rule registered via [AiTestHttpInterceptor.addMockRule].
///
/// [pattern] is matched against the request URL as a substring first; if
/// [RegExp] construction succeeds and the substring check fails, the pattern
/// is retried as a regular expression. This means simple substring patterns
/// like `/monitors` work without escaping, while callers can also supply full
/// regex patterns like `r'/monitors/\d+'`.
///
/// [status] is the synthesized HTTP status code.
/// [body] is the raw response body string (JSON or otherwise).
/// [headers] are additional response headers returned to the caller.
final class MockRule {
  /// Creates a [MockRule].
  const MockRule({
    required this.pattern,
    required this.status,
    required this.body,
    this.headers = const {},
  });

  /// URL substring or regex pattern that triggers this rule.
  final String pattern;

  /// Synthesized HTTP status code.
  final int status;

  /// Raw response body (JSON string or other text).
  final String body;

  /// Extra response headers included in the synthesized [MagicResponse].
  final Map<String, String> headers;

  /// Returns true when [url] matches this rule's [pattern].
  ///
  /// Match order:
  /// 1. Substring containment (fast path for simple patterns).
  /// 2. Full-string [RegExp] match when substring check fails.
  bool matches(String url) {
    if (url.contains(pattern)) return true;
    try {
      return RegExp(pattern).hasMatch(url);
    } catch (_) {
      return false;
    }
  }
}

/// Auto-collecting HTTP interceptor for the V3 ai_test_flutter plugin.
///
/// Captures every request/response pair into a ring buffer (max 50 entries)
/// so the `ext.aitest.network_requests` VM Service extension (Step 12) can
/// serve the recent network history to the LLM agent without any additional
/// infrastructure.
///
/// ## Mock rules
///
/// The `ext.aitest.mock_http` VM Service extension (Step 13) registers mock
/// rules via [addMockRule]. During [onRequest], rules are checked in LIFO
/// order (last-registered wins). When a rule matches the request URL, a
/// synthesized [MagicResponse] is returned immediately, short-circuiting
/// the network.
///
/// Rules are held in a static [List] scoped to the Dart isolate. They are
/// cleared automatically on hot-restart because Dart statics reset when
/// `main()` re-runs. Call [clearMockRules] for explicit test cleanup.
///
/// ## Registration
///
/// Call [register] from [AiTestPluginV3.install]. [register] is idempotent:
/// a second call is a silent no-op guarded by [_registered].
///
/// ```dart
/// AiTestHttpInterceptor.register();
/// ```
///
/// ## Magic availability
///
/// If Magic's network service is not bound (`Magic.bound('network')` returns
/// false), [register] logs a warning and returns without throwing. This
/// allows the plugin to operate against pure-Flutter apps that do not use
/// the Magic HTTP facade.
///
/// ## Thread safety
///
/// The ring buffer and mock-rule list are not `synchronized`. All VM Service
/// extension calls arrive on the root isolate, so no cross-isolate mutation
/// occurs.
class AiTestHttpInterceptor extends MagicNetworkInterceptor {
  AiTestHttpInterceptor._();

  // ---------------------------------------------------------------------------
  // Singleton
  // ---------------------------------------------------------------------------

  static final AiTestHttpInterceptor _instance = AiTestHttpInterceptor._();

  /// The singleton interceptor instance.
  static AiTestHttpInterceptor get instance => _instance;

  // ---------------------------------------------------------------------------
  // Mock rules
  // ---------------------------------------------------------------------------

  /// Active mock rules, stored in insertion order.
  ///
  /// [onRequest] iterates from the end (LIFO) so the last-registered rule
  /// wins when multiple rules match the same URL.
  static final List<MockRule> _mockRules = [];

  /// Appends a mock rule from the supplied [rule] map.
  ///
  /// Required keys:
  /// - `'pattern'` (String) — URL substring or regex.
  /// - `'status'` (int) — HTTP status code for the synthesized response.
  /// - `'body'` (String) — raw response body.
  ///
  /// Optional keys:
  /// - `'contentType'` (String) — included as `content-type` response header.
  /// - `'headers'` (`Map<String, String>`) — extra response headers.
  static void addMockRule(Map<String, dynamic> rule) {
    final pattern = rule['pattern'] as String;
    final status = rule['status'] as int;
    final body = (rule['body'] as String?) ?? '';

    final Map<String, String> headers = {};
    if (rule['contentType'] is String) {
      headers['content-type'] = rule['contentType'] as String;
    }
    if (rule['headers'] is Map) {
      (rule['headers'] as Map).forEach((k, v) {
        headers[k.toString()] = v.toString();
      });
    }

    _mockRules.add(MockRule(
        pattern: pattern, status: status, body: body, headers: headers));
  }

  /// Removes all registered mock rules.
  ///
  /// Call this in test teardowns to return the interceptor to pass-through
  /// mode. Hot-restart clears rules automatically (Dart statics reset).
  static void clearMockRules() => _mockRules.clear();

  // ---------------------------------------------------------------------------
  // Ring buffer
  // ---------------------------------------------------------------------------

  static const int _maxCapacity = 50;

  /// Pending request start times keyed by URL+method for duration tracking.
  final Map<String, DateTime> _pending = {};

  /// Ring buffer of captured request/response records.
  final Queue<Map<String, dynamic>> _buffer = Queue();

  // ---------------------------------------------------------------------------
  // Stream — new-entry broadcast
  // ---------------------------------------------------------------------------

  /// Lazy broadcast controller. Allocated on first [newEntries] access.
  ///
  /// The singleton lives for the lifetime of the isolate; no explicit dispose
  /// is needed. Listeners subscribe and cancel individually — the controller
  /// itself is never closed.
  StreamController<Map<String, dynamic>>? _streamController;

  /// A broadcast stream that emits each entry as it enters the ring buffer.
  ///
  /// Subscribe here to receive real-time HTTP records without polling.
  /// The stream is broadcast (multiple listeners supported simultaneously).
  /// Each emitted map is the same deep-copy produced by [recentRequests].
  Stream<Map<String, dynamic>> get newEntries {
    _streamController ??= StreamController<Map<String, dynamic>>.broadcast();
    return _streamController!.stream;
  }

  // ---------------------------------------------------------------------------
  // Registration
  // ---------------------------------------------------------------------------

  static bool _registered = false;

  /// Whether the interceptor has been successfully wired into Magic's Dio
  /// driver. Exposed so the V3 install pump can stop retrying once
  /// registration lands (Magic.bound('network') may flip from false to true
  /// between install() and Magic.init() completion).
  static bool get isRegistered => _registered;

  /// Registers the interceptor with Magic's NetworkDriver.
  ///
  /// Idempotent: a second call is a silent no-op.
  /// Gracefully degrades if Magic is not present (`Magic.bound('network')`
  /// returns false) — logs a warning and returns without throwing.
  static void register() {
    if (_registered) return;

    if (!Magic.bound('network')) {
      developer.log(
        '[ai-test-v3] AiTestHttpInterceptor: Magic network driver not bound '
        '— deferring; call register() again after Magic.init() completes.',
        name: 'ai-test',
      );
      // Do NOT set _registered: allow the next install()/AppBooted callback
      // to retry once Magic has registered the network service. Otherwise we
      // silently no-op forever (production bug: install() runs before
      // Magic.init() in lib/main.dart so the first attempt always fails).
      return;
    }

    try {
      Magic.make<NetworkDriver>('network').addInterceptor(_instance);
      developer.log(
        '[ai-test-v3] AiTestHttpInterceptor registered.',
        name: 'ai-test',
      );
    } catch (e) {
      developer.log(
        '[ai-test-v3] AiTestHttpInterceptor: registration failed: $e',
        name: 'ai-test',
      );
    }

    _registered = true;
  }

  // ---------------------------------------------------------------------------
  // MagicNetworkInterceptor overrides
  // ---------------------------------------------------------------------------

  @override
  dynamic onRequest(MagicRequest request) {
    // 1. Check mock rules in LIFO order — last-registered rule wins.
    //    A matching rule short-circuits the network by returning a synthesized
    //    MagicResponse. The DioNetworkDriver's InterceptorsWrapper only calls
    //    handler.next when onRequest returns a MagicRequest; any other type
    //    causes the wrapper to skip handler.next, so returning MagicResponse
    //    here signals the short-circuit to callers that inspect the result
    //    directly (e.g., tests and the DioNetworkDriver's mock-aware wrapper).
    for (var i = _mockRules.length - 1; i >= 0; i--) {
      final rule = _mockRules[i];
      if (rule.matches(request.url)) {
        developer.log(
          '[ai-test-v3] mock_http matched "${rule.pattern}" → ${rule.status}',
          name: 'ai-test',
        );
        return MagicResponse(
          data: rule.body,
          statusCode: rule.status,
          headers: rule.headers,
          message: null,
        );
      }
    }

    // 2. No rule matched — record the request start time and let it proceed.
    _pending['${request.method}:${request.url}'] = DateTime.now();
    return request;
  }

  @override
  dynamic onResponse(MagicResponse response) {
    // 1. Compute duration from the matching pending entry, if available.
    //    The response carries no URL reference, so we pop the most recent
    //    pending entry (FIFO — single outstanding request in the typical case).
    final entry = _buildEntry(response: response);
    _enqueue(entry);
    return response;
  }

  @override
  dynamic onError(MagicError error) {
    // Capture errors as records with the response status (0 if absent).
    final entry = _buildEntry(
      request: error.request,
      response: error.response,
      isError: true,
    );
    _enqueue(entry);
    return error;
  }

  // ---------------------------------------------------------------------------
  // Public read API
  // ---------------------------------------------------------------------------

  /// Returns an immutable snapshot of recent HTTP request/response records.
  ///
  /// [limit] caps the number of returned entries to the N most recent. When
  /// omitted, all buffered records are returned (up to 50).
  ///
  /// Each record contains:
  /// - `url` (String): the request URL.
  /// - `method` (String): the HTTP method (GET, POST, …).
  /// - `statusCode` (int): the response status code (0 on network error).
  /// - `durationMs` (int?): elapsed milliseconds, or null when unavailable.
  /// - `isError` (bool): true when the request ended in a network error.
  /// - `timestamp` (String): ISO-8601 capture time.
  static List<Map<String, dynamic>> recentRequests({int? limit}) {
    final snapshot = _instance._buffer.toList();
    final slice = (limit != null && limit < snapshot.length)
        ? snapshot.sublist(snapshot.length - limit)
        : snapshot;
    // Return deep-copied maps so callers cannot mutate internal state.
    return slice.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _buildEntry({
    MagicRequest? request,
    MagicResponse? response,
    bool isError = false,
  }) {
    // Pop the earliest pending entry to compute duration (best-effort).
    int? durationMs;
    String url = request?.url ?? '';
    String method = request?.method ?? '';

    if (request != null) {
      final key = '${request.method}:${request.url}';
      final started = _pending.remove(key);
      if (started != null) {
        durationMs = DateTime.now().difference(started).inMilliseconds;
      }
    } else if (_pending.isNotEmpty) {
      // No request object on response — consume the earliest pending entry.
      final key = _pending.keys.first;
      final started = _pending.remove(key);
      final parts = key.split(':');
      method = parts.first;
      url = parts.length > 1 ? parts.sublist(1).join(':') : '';
      if (started != null) {
        durationMs = DateTime.now().difference(started).inMilliseconds;
      }
    }

    return {
      'url': url,
      'method': method,
      'statusCode': response?.statusCode ?? 0,
      'durationMs': durationMs,
      'isError': isError,
      'timestamp': DateTime.now().toIso8601String(),
    };
  }

  void _enqueue(Map<String, dynamic> entry) {
    if (_buffer.length >= _maxCapacity) {
      _buffer.removeFirst();
    }
    _buffer.addLast(entry);
    // Notify stream subscribers if the controller has been allocated.
    _streamController?.add(Map<String, dynamic>.from(entry));
  }

  // ---------------------------------------------------------------------------
  // Test support
  // ---------------------------------------------------------------------------

  /// Resets internal state for use in tests.
  ///
  /// Clears the ring buffer, pending map, mock rules, and [_registered] flag
  /// so tests start from a clean slate. Must NOT be called from production
  /// code.
  // ignore_for_testing
  static void resetForTesting() {
    _instance._buffer.clear();
    _instance._pending.clear();
    _mockRules.clear();
    _registered = false;
  }
}
