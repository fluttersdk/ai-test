# ai-test — Flutter Web LLM-Agent Control (V3)

> MCP-only single-channel via Dart VM Service custom extensions. No Playwright, no DOM mirror, no Shadow DOM projection.

Two packages bridge a running Flutter web app to an LLM coding agent (Claude / Cursor / similar) so the agent can drive, inspect, and verify the app A-Z over a single MCP stdio surface.

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
flutter run -d chrome --no-dds --dart-define=AI_TEST=1
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

```bash
# Wire-once in lib/main.dart inside `if (kIsWeb && kDebugMode)`:
AiTestPluginV3.install();
runApp(
  RepaintBoundary(
    key: AiTestPluginV3.rootRepaintBoundaryKey,
    child: yourApp,
  ),
);

# Then launch via the CLI:
dart run ai_test_flutter:ai_test_flutter start    # boots flutter run -d chrome + writes ~/.ai-test/state.json
dart run ai_test_flutter:ai_test_flutter status   # JSON status
dart run ai_test_flutter:ai_test_flutter doctor   # environment preflight
dart run ai_test_flutter:ai_test_flutter stop     # SIGTERM + state.json delete
```

The compile-time `kIsWeb && kDebugMode` outer guard lets dart2js prove the entire branch dead in release; production builds emit zero V3 bytes.

## State inspection

Replaces V2's typed `inspect_state` per Oracle cull (dart2js has no reflection so a typed wrapper would be a fake hint):

```typescript
await client.callTool({
  name: 'flutter_evaluate',
  arguments: { expression: 'Magic.find<MonitorController>().rxState.value.toString()' },
});
```

Form data lives in the snapshot YAML's `magicFormField:` enrichment per ref.

## References

- Architecture deep-dive: [V3_OVERVIEW.md](V3_OVERVIEW.md)
- V1 forensics: [V1_RESULT.md](V1_RESULT.md)
- Plan: `.ac/plans/ai-test-v3/plan.md` (28 steps, 9 waves)
- Wave 1 spike: `.ac/plans/ai-test-v3/evidence/wave-1-spike.md`
- Walkthrough: `.ac/plans/ai-test-v3/evidence/walkthrough.ts` + readme
