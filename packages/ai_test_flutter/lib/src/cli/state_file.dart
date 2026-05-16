import 'dart:convert';
import 'dart:io';

/// Owns the `~/.ai-test/state.json` file consumed by every CLI command and the
/// MCP server.
///
/// Single source of truth for the running `flutter run` instance: PID, scraped
/// VM service URI, ports, start timestamp, profile, and project root. All
/// commands (`start`, `stop`, `status`, `doctor`, `logs`, `restart`) interact
/// with the same file via this class so the on-disk shape stays consistent.
///
/// Atomicity: [write] persists to a sibling `.tmp` file first and then renames
/// it over `state.json`. POSIX `rename(2)` is atomic on the same filesystem,
/// so a reader (e.g. `status`) never sees a half-written file.
///
/// Cross-platform home resolution: prefers `HOME` (POSIX) and falls back to
/// `USERPROFILE` (Windows). Tests inject a temp dir via [debugHomeOverride].
class StateFile {
  StateFile._();

  /// Test-only override that replaces the resolved home directory.
  ///
  /// Set this in `setUp` to redirect [path] to a per-test temp dir; restore
  /// to `null` in `tearDown`. Never set this in production code.
  static String? debugHomeOverride;

  /// Absolute path to `~/.ai-test/state.json`.
  static String get path {
    final String home = _resolveHome();
    return '$home${Platform.pathSeparator}.ai-test'
        '${Platform.pathSeparator}state.json';
  }

  /// Writes [state] as pretty JSON to [path] atomically.
  ///
  /// Creates `~/.ai-test/` if missing (Must NOT: fail when the directory does
  /// not yet exist). Persists to `state.json.tmp` first, then renames over
  /// `state.json` so concurrent readers never observe a partial file.
  static Future<void> write(Map<String, dynamic> state) async {
    // 1. Ensure the parent directory exists.
    final Directory parent = Directory(_dirname(path));
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }

    // 2. Write the tmp sibling.
    final String tmpPath = '$path.tmp';
    final File tmp = File(tmpPath);
    const JsonEncoder encoder = JsonEncoder.withIndent('  ');
    tmp.writeAsStringSync(encoder.convert(state), flush: true);

    // 3. Atomic rename over the live file.
    tmp.renameSync(path);
  }

  /// Returns the decoded state map, or `null` when `state.json` is absent.
  ///
  /// Returns `null` (not throw) on missing file because every consumer treats
  /// "no state" as a valid state ("no flutter run is recorded").
  static Future<Map<String, dynamic>?> read() async {
    final File file = File(path);
    if (!file.existsSync()) {
      return null;
    }
    final String raw = file.readAsStringSync();
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Removes `state.json` if present. Idempotent — no throw when absent.
  static Future<void> delete() async {
    final File file = File(path);
    if (file.existsSync()) {
      file.deleteSync();
    }
  }

  static String _resolveHome() {
    if (debugHomeOverride != null) {
      return debugHomeOverride!;
    }
    final String? home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) {
      throw StateError(
          'Cannot resolve home directory: neither HOME nor USERPROFILE is set');
    }
    return home;
  }

  static String _dirname(String filePath) {
    final int idx = filePath.lastIndexOf(Platform.pathSeparator);
    return idx < 0 ? '.' : filePath.substring(0, idx);
  }
}
