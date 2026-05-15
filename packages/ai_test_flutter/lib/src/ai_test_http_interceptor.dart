import 'dart:collection';
import 'dart:developer' as developer;

import 'package:magic/magic.dart';

/// Auto-collecting HTTP interceptor for the V3 ai_test_flutter plugin.
///
/// Captures every request/response pair into a ring buffer (max 50 entries)
/// so the `ext.aitest.network_requests` VM Service extension (Step 12) can
/// serve the recent network history to the LLM agent without any additional
/// infrastructure.
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
/// The ring buffer is not `synchronized`. All VM Service extension calls
/// arrive on the root isolate, so no cross-isolate mutation occurs.
class AiTestHttpInterceptor extends MagicNetworkInterceptor {
  AiTestHttpInterceptor._();

  // ---------------------------------------------------------------------------
  // Singleton
  // ---------------------------------------------------------------------------

  static final AiTestHttpInterceptor _instance = AiTestHttpInterceptor._();

  /// The singleton interceptor instance.
  static AiTestHttpInterceptor get instance => _instance;

  // ---------------------------------------------------------------------------
  // Ring buffer
  // ---------------------------------------------------------------------------

  static const int _maxCapacity = 50;

  /// Pending request start times keyed by URL+method for duration tracking.
  final Map<String, DateTime> _pending = {};

  /// Ring buffer of captured request/response records.
  final Queue<Map<String, dynamic>> _buffer = Queue();

  // ---------------------------------------------------------------------------
  // Registration
  // ---------------------------------------------------------------------------

  static bool _registered = false;

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
        '— skipping interceptor registration.',
        name: 'ai-test',
      );
      _registered = true;
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
    // Record the request start time keyed by a composite identifier.
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
  }

  // ---------------------------------------------------------------------------
  // Test support
  // ---------------------------------------------------------------------------

  /// Resets internal state for use in tests.
  ///
  /// Clears the ring buffer, pending map, and [_registered] flag so tests
  /// start from a clean slate. Must NOT be called from production code.
  // ignore_for_testing
  static void resetForTesting() {
    _instance._buffer.clear();
    _instance._pending.clear();
    _registered = false;
  }
}
