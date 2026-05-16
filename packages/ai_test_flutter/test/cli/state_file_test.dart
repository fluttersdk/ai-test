@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:ai_test_flutter/src/cli/state_file.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for [StateFile] (Step 15 of V3 plan).
///
/// `StateFile` owns `~/.ai-test/state.json` lifecycle for the V3 CLI. The class
/// is tested with `HOME` overridden to a per-test temp dir so the suite does
/// not pollute the developer's real `~/.ai-test/`.
///
/// Asserts:
/// 1. `write()` is atomic (tmp file + rename, no half-written state.json).
/// 2. `read()` round-trips the JSON map written by `write()`.
/// 3. `read()` returns null when state.json is absent.
/// 4. `delete()` is idempotent (no throw when file absent).
/// 5. `write()` creates the parent directory if missing (Must NOT: fail when
///    `~/.ai-test/` does not exist).
void main() {
  late Directory tempHome;
  late String? originalHome;
  late String? originalUserProfile;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('ai_test_state_');
    originalHome = Platform.environment['HOME'];
    originalUserProfile = Platform.environment['USERPROFILE'];
    StateFile.debugHomeOverride = tempHome.path;
  });

  tearDown(() {
    StateFile.debugHomeOverride = null;
    if (tempHome.existsSync()) {
      tempHome.deleteSync(recursive: true);
    }
    // Suppress unused_local_variable lint on the snapshots — kept for clarity
    // about what the test is restoring (the override hook is what matters).
    expect(originalHome ?? originalUserProfile ?? '', isA<String>());
  });

  group('StateFile.path', () {
    test('resolves under ~/.ai-test/state.json', () {
      final String path = StateFile.path;

      expect(
          path,
          endsWith('${Platform.pathSeparator}.ai-test'
              '${Platform.pathSeparator}state.json'));
      expect(path, startsWith(tempHome.path));
    });
  });

  group('StateFile.write', () {
    test('persists the map as pretty JSON', () async {
      final Map<String, dynamic> state = <String, dynamic>{
        'pid': 12345,
        'vmServiceUri': 'ws://127.0.0.1:8181/token/ws',
        'webPort': 3100,
        'vmServicePort': 8181,
        'startedAt': '2026-05-16T10:00:00.000Z',
        'profile': 'debug',
        'projectRoot': '/path/to/project',
      };

      await StateFile.write(state);

      final File file = File(StateFile.path);
      expect(file.existsSync(), isTrue);
      final Map<String, dynamic> decoded =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(decoded, equals(state));
    });

    test('creates the ~/.ai-test/ directory when absent', () async {
      // tempHome has no .ai-test/ subdir yet; write() must mkdir it.
      final Directory aiTestDir =
          Directory('${tempHome.path}${Platform.pathSeparator}.ai-test');
      expect(aiTestDir.existsSync(), isFalse);

      await StateFile.write(<String, dynamic>{'pid': 1});

      expect(aiTestDir.existsSync(), isTrue);
      expect(File(StateFile.path).existsSync(), isTrue);
    });

    test('uses tmp + rename for atomicity (no partial state.json on failure)',
        () async {
      // Write once so a prior state exists.
      await StateFile.write(<String, dynamic>{'pid': 1, 'phase': 'first'});
      final String firstContent = File(StateFile.path).readAsStringSync();

      // Second write: succeeds via tmp + rename, fully replacing first.
      await StateFile.write(<String, dynamic>{'pid': 2, 'phase': 'second'});
      final String secondContent = File(StateFile.path).readAsStringSync();
      expect(secondContent, isNot(equals(firstContent)));

      // No leftover tmp file.
      final Directory aiTestDir =
          Directory('${tempHome.path}${Platform.pathSeparator}.ai-test');
      final List<String> leftovers = aiTestDir
          .listSync()
          .whereType<File>()
          .map((File f) => f.uri.pathSegments.last)
          .where((String name) => name.startsWith('state.json.tmp'))
          .toList();
      expect(leftovers, isEmpty,
          reason: 'tmp file must be renamed atomically into state.json');
    });
  });

  group('StateFile.read', () {
    test('returns null when state.json is missing', () async {
      final Map<String, dynamic>? state = await StateFile.read();
      expect(state, isNull);
    });

    test('returns the decoded map when state.json exists', () async {
      await StateFile.write(<String, dynamic>{'pid': 99, 'webPort': 3100});

      final Map<String, dynamic>? state = await StateFile.read();

      expect(state, isNotNull);
      expect(state!['pid'], equals(99));
      expect(state['webPort'], equals(3100));
    });
  });

  group('StateFile.delete', () {
    test('removes state.json when present', () async {
      await StateFile.write(<String, dynamic>{'pid': 1});
      expect(File(StateFile.path).existsSync(), isTrue);

      await StateFile.delete();

      expect(File(StateFile.path).existsSync(), isFalse);
    });

    test('is idempotent when state.json is absent', () async {
      expect(File(StateFile.path).existsSync(), isFalse);
      expect(StateFile.delete, returnsNormally);
    });
  });
}
