# ai-test — Flutter LLM-Agent Control (V3)

> MCP-only single-channel via Dart VM Service custom extensions. No Playwright, no DOM mirror, no Shadow DOM projection. **Cross-platform**: web (Chrome), macOS / Linux / Windows desktop, iOS / Android simulator + device.

Two packages bridge a running Flutter app to an LLM coding agent (Claude / Cursor / similar) so the agent can drive, inspect, and verify the app A-Z over a single MCP stdio surface. Every interaction flows through the Dart VM Service, which is available on every Flutter target — web debug, desktop debug, and mobile debug all expose the same `ext.aitest.*` extension surface.

| Package | Path | Role |
|---|---|---|
| `ai_test_flutter` | `packages/ai_test_flutter/` | Flutter Dart plugin: `AiTestPluginV3.install()` registers ~18 `ext.aitest.*` VM Service custom extensions (snapshot/tap/type/scroll/screenshot/network/etc.) plus a Dart `bin/` CLI for lifecycle management. |
| `ai_test_node` | `packages/ai_test_node/` | TypeScript MCP server. 19 tools wrap the Dart-side extensions over a single VM Service WebSocket. |

## V3 Architecture

```
agent (LLM, IDE)
  │
  ▼  MCP stdio
ai-test-mcp (TypeScript)
  │
  ▼  Dart VM Service Protocol (one WebSocket)
flutter run -d <chrome|macos|linux|windows|ios|android> \
  --no-dds --dart-define=AI_TEST=1
  │
  ▼  developer.registerExtension dispatch
ai_test_flutter (Dart) ext.aitest.*
  │
  ▼  WidgetsBinding / Element walk / RenderRepaintBoundary / ...
running widget tree
```

V0 / V1 / V2 attempted Shadow DOM projection / mirror DOM / native Semantics + Playwright. V2 dual-chrome split + DOM input race were the V2 mission failure. V3 collapses everything into one channel; Playwright eliminated.

## Launch

From the consumer Flutter app's repo (e.g. `uptizm-app/`):

```dart
// Wire-once in lib/main.dart inside `if (kDebugMode)`:
if (kDebugMode) {
  AiTestPluginV3.install();
}
runApp(kDebugMode ? RepaintBoundary(child: yourApp) : yourApp);
```

```bash
# Web (default — back-compat):
dart run ai_test_flutter:ai_test_flutter start
# Desktop:
dart run ai_test_flutter:ai_test_flutter start --device=macos
dart run ai_test_flutter:ai_test_flutter start --device=linux
dart run ai_test_flutter:ai_test_flutter start --device=windows
# Mobile (iOS simulator UDID or Android serial accepted as device id):
dart run ai_test_flutter:ai_test_flutter start --device=<simulator-id>

dart run ai_test_flutter:ai_test_flutter status   # JSON status
dart run ai_test_flutter:ai_test_flutter doctor   # environment preflight
dart run ai_test_flutter:ai_test_flutter stop     # SIGTERM + state.json delete
```

The compile-time `kDebugMode` guard lets dart2js (web) and dart2native (desktop / mobile AOT) tree-shake the entire V3 branch out of release bundles on every platform. The D6 Chrome reaper + PID capture only fire when `--device=chrome` (default); other targets skip them because there is no Chrome process tree to clean up.

## State inspection

Replaces V2's typed `inspect_state` per Oracle cull (dart2js has no reflection so a typed wrapper would be a fake hint):

```typescript
await client.callTool({
  name: 'flutter_evaluate',
  arguments: { expression: 'Magic.find<MonitorController>().rxState.value.toString()' },
});
```

Form data lives in the snapshot YAML's `magicFormField:` enrichment per ref.

## Disabling the plugin

To prevent `AiTestPluginV3.install()` from registering any extensions without
removing the call from `main.dart`, pass `--dart-define=AI_TEST_DISABLE=1` at
build or run time:

```bash
flutter run -d chrome --dart-define=AI_TEST_DISABLE=1
flutter build web --dart-define=AI_TEST_DISABLE=1
```

Accepted truthy values (case-insensitive): `1`, `true`, `yes`.

`String.fromEnvironment` is used internally (not `Platform.environment`)
because web targets have no `Platform.environment`. The value is baked into the
compiled binary at build time; changing it requires a rebuild.

The `kIsWeb && kDebugMode` outer gate in `main.dart` is still the primary
tree-shaking guard for release builds. `AI_TEST_DISABLE` is a secondary runtime
guard for debug/staging builds where the outer gate passes but the agent
instrumentation should not activate (e.g. CI preview builds, automated UI
regression runs that do not use the MCP server).

> The `AiTestPluginV3.install()` line in `main.dart` must remain present.
> The guard fires inside `install()`, not at the call site.

## References

- Architecture deep-dive: [V3_OVERVIEW.md](V3_OVERVIEW.md)
- V1 forensics: [V1_RESULT.md](V1_RESULT.md)
- Plan: `.ac/plans/ai-test-v3/plan.md` (28 steps, 9 waves)
- Wave 1 spike: `.ac/plans/ai-test-v3/evidence/wave-1-spike.md`
- Walkthrough: `.ac/plans/ai-test-v3/evidence/walkthrough.ts` + readme
