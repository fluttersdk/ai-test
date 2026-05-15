import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;

import 'package:logging/logging.dart';

/// Auto-collecting log sink for the V3 ai_test_flutter plugin.
///
/// Subscribes to `Logger.root.onRecord` from `package:logging` and retains
/// a ring buffer of the 100 most recent records. The
/// `ext.aitest.console_messages` VM Service extension (Step 12) reads this
/// buffer to deliver log history to the LLM agent.
///
/// ## Registration
///
/// Call [register] from [AiTestPluginV3.install]. [register] is idempotent:
/// a second call is a silent no-op guarded by [_subscribed].
///
/// ```dart
/// AiTestLogSink.register();
/// ```
///
/// ## Compatibility
///
/// `package:logging` is a transitive dependency of the `magic` package
/// (via `package:logger`'s own dependency tree). No direct dep addition is
/// needed beyond the explicit `logging: ^1.2.0` pin in pubspec.yaml, which
/// locks the version contract.
class AiTestLogSink {
  AiTestLogSink._();

  // ---------------------------------------------------------------------------
  // Ring buffer
  // ---------------------------------------------------------------------------

  static const int _maxCapacity = 100;

  /// Ring buffer of captured log records.
  static final Queue<Map<String, dynamic>> _buffer = Queue();

  // ---------------------------------------------------------------------------
  // Registration
  // ---------------------------------------------------------------------------

  static bool _subscribed = false;
  static StreamSubscription<LogRecord>? _subscription;

  /// Subscribes to `Logger.root.onRecord` and starts collecting records.
  ///
  /// Idempotent: a second call is a silent no-op (the subscription flag
  /// prevents duplicate listeners, which would double-count every record).
  static void register() {
    if (_subscribed) return;

    _subscription = Logger.root.onRecord.listen(_onRecord);
    _subscribed = true;

    developer.log(
      '[ai-test-v3] AiTestLogSink registered.',
      name: 'ai-test',
    );
  }

  // ---------------------------------------------------------------------------
  // Public read API
  // ---------------------------------------------------------------------------

  /// Returns an immutable snapshot of recent log records.
  ///
  /// [limit] caps the number of returned entries to the N most recent. When
  /// omitted, all buffered records are returned (up to 100).
  ///
  /// [minLevel] filters out records whose [Level.value] is strictly below the
  /// given threshold. Use [Level.INFO.value] (800) to suppress fine/config
  /// noise, [Level.WARNING.value] (900) for warnings and above, etc.
  ///
  /// Each record contains:
  /// - `level` (String): the level name (INFO, WARNING, SEVERE, …).
  /// - `levelValue` (int): the numeric level value for client-side filtering.
  /// - `message` (String): the log message.
  /// - `loggerName` (String): the originating Logger's name.
  /// - `time` (String): ISO-8601 timestamp from [LogRecord.time].
  /// - `error` (String?): `error.toString()` when the record carries an error.
  /// - `stackTrace` (String?): stack trace string when present.
  static List<Map<String, dynamic>> recentLogs({int? limit, int? minLevel}) {
    var snapshot = _buffer.toList();

    // 1. Apply level filter when requested.
    if (minLevel != null) {
      snapshot =
          snapshot.where((e) => (e['levelValue'] as int) >= minLevel).toList();
    }

    // 2. Apply limit to the N most-recent matching entries.
    final slice = (limit != null && limit < snapshot.length)
        ? snapshot.sublist(snapshot.length - limit)
        : snapshot;

    // 3. Return deep-copied maps so callers cannot mutate internal state.
    return slice.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  static void _onRecord(LogRecord record) {
    final entry = <String, dynamic>{
      'level': record.level.name,
      'levelValue': record.level.value,
      'message': record.message,
      'loggerName': record.loggerName,
      'time': record.time.toIso8601String(),
      if (record.error != null) 'error': record.error.toString(),
      if (record.stackTrace != null) 'stackTrace': record.stackTrace.toString(),
    };

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
  /// Cancels the active subscription, clears the ring buffer, and resets
  /// the [_subscribed] flag so tests can call [register] afresh. Must NOT
  /// be called from production code.
  static void resetForTesting() {
    _subscription?.cancel();
    _subscription = null;
    _buffer.clear();
    _subscribed = false;
  }
}
