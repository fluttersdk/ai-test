# V3 — MCP-only Single-Channel Flutter Web LLM-Agent Control

> Architecture deep-dive. For day-to-day usage see the package READMEs.

## Mission

Give an LLM agent (Claude, Cursor, Windsurf, custom) the ability to drive a
running Flutter web app A-Z without DOM scraping, without Playwright, without
a screen mirror. Single MCP surface; everything flows through the Dart VM
Service.

## Three packages

| Package | Path | Role |
|---|---|---|
| `ai_test_flutter` | `packages/ai_test_flutter/` | Flutter Dart plugin. `AiTestPluginV3.install()` registers ~18 `ext.aitest.*` VM Service custom extensions. |
| `ai_test_flutter` (CLI) | `packages/ai_test_flutter/bin/` | Dart `bin/` CLI: `start`/`stop`/`status`/`doctor`/`logs`/`restart` over `~/.ai-test/state.json`. |
| `ai_test_node` | `packages/ai_test_node/` | TypeScript MCP server. 19 tools wrap the Dart-side extensions over a single VM Service WebSocket. |

## Activation

```dart
// uptizm-app/lib/main.dart
if (kIsWeb && kDebugMode) {
  AiTestPluginV3.install();
}
runApp(
  kIsWeb && kDebugMode
      ? RepaintBoundary(
          key: AiTestPluginV3.rootRepaintBoundaryKey,
          child: app,
        )
      : app,
);
```

The compile-time `kIsWeb && kDebugMode` outer guard lets dart2js prove the
entire branch dead in release. Release builds emit zero V3 bytes (verified
via tree-shake grep in Step 26).

## Why VM Service custom extensions, not DOM mirror

V0 / V1 / V2 attempted Shadow DOM projection + native Flutter Semantics
mirror + Playwright. All three architectures failed against Wind framework
apps. Wave 1 spike confirmed the fundamental issue: the dual-chrome split
between Playwright's browser and `flutter run -d chrome`'s browser plus the
DOM input race make even the happy path unreliable. V3 collapses everything
into one channel.

VM Service custom extensions are Dart's first-class debug-time RPC mechanism.
`developer.registerExtension('ext.aitest.snapshot', handler)` exposes a JSON
endpoint the MCP server reaches over the same WebSocket Flutter DevTools
uses. No second browser, no race, no glasspane.

## Wire path

```
agent (LLM, IDE)
  │
  ▼  stdio JSON-RPC (MCP protocol)
ai-test-mcp (TypeScript, packages/ai_test_node/src/cli.ts)
  │
  ▼  ws://127.0.0.1:<port>/<token>/ws (Dart VM Service Protocol)
flutter run -d chrome --no-dds --dart-define=AI_TEST=1 --web-port=3100
  │
  ▼  developer.registerExtension dispatch
ai_test_flutter (Dart) ext.aitest.*
  │
  ▼  WidgetsBinding.handlePointerEvent / EditableTextState.requestKeyboard /
     RenderRepaintBoundary.toImage / Scrollable.maybeOf / Element.visitAncestorElements
running widget tree
```

## Tool catalog (19, post Oracle cull)

| Tool | Wraps | Group |
|---|---|---|
| `flutter_navigate` | `ext.aitest.navigate` | navigation |
| `flutter_navigate_back` | `ext.aitest.navigate_back` | navigation |
| `flutter_get_routes` | `ext.aitest.get_routes` | navigation |
| `flutter_close_app` | `vmClient.disconnect` (soft) | navigation |
| `flutter_resize` | DEFERRED ALPHA — devtools workaround | navigation |
| `flutter_tap` | `ext.aitest.tap` | interaction |
| `flutter_type` | `ext.aitest.type` (controller mutation) | interaction |
| `flutter_press_key` | `ext.aitest.press_key` (HardwareKeyboard) | interaction |
| `flutter_hover` | `ext.aitest.hover` (PointerHoverEvent) | interaction |
| `flutter_drag` | `ext.aitest.drag` (Down + 5×Move + Up) | interaction |
| `flutter_select_option` | `ext.aitest.select_option` (DropdownButton.onChanged) | interaction |
| `flutter_file_upload` | DEFERRED V3.1 — browser File API | interaction |
| `flutter_snapshot` | `ext.aitest.snapshot` (Semantics walk + ref system) | snapshot |
| `flutter_screenshot` | `ext.aitest.screenshot` (RepaintBoundary.toImage + JPEG/PNG) | snapshot |
| `flutter_evaluate` | VM Service `evaluate` RPC + rootLib | snapshot |
| `flutter_wait_for` | `ext.aitest.wait_for` (poll Element/Semantics tree) | snapshot |
| `flutter_network_requests` | `ext.aitest.network_requests` (Dio interceptor ring) | network |
| `flutter_console_messages` | `ext.aitest.console_messages` (Logger.root.onRecord ring) | network |
| `flutter_mock_http` | `ext.aitest.mock_http` (interceptor short-circuit rule) | network |

**Dropped per Oracle cull**: `flutter_inspect_state`, `flutter_inspect_form`,
`flutter_handle_dialog`, `flutter_hot_reload`. State inspection uses
`flutter_evaluate("Magic.find<X>().rxState.value.toString()")`. Form names
live inside the snapshot YAML as `magicFormField: <name>` per ref.

## Decision log (locked, see plan & spike evidence)

| Decision | Choice | Why |
|---|---|---|
| Activation gate | `kDebugMode` only | Text-typing controller-mutation requires debug binding (Flutter #87990) |
| Text input primary path | `controller.value = TextEditingValue(...)` | Spike confirmed; `SystemChannels.textInput.setEditingState` is NO-OP outside test binding |
| DDS namespace handling | Defensive map (built-ins prefix; custom `ext.*` stays bare on Flutter 3.41+) | Spike-observed |
| Snapshot ref shape | Playwright-MCP `[ref=eN]` keyed off SemanticsNode.id | Agents already trained on this vocab |
| Tool surface size | 19 (post Oracle cull) | Avoids fake-hint typed wrappers; `evaluate` covers state inspection |
| CLI scope | 6 verbs (start/stop/status/doctor/logs/restart) | Full lifecycle without bash glue |
| Screenshot format | JPEG q70 default + PNG opt-in | 40-120KB payload fits MCP context budget |
| Hot-restart safety | try/catch ArgumentError per `registerExtension` | VM extension table persists across hot-restart; static guard would break |
| Playwright | Eliminated entirely | V2 dual-chrome split was the V2 mission failure |

## Known limitations (V3 → V3.1)

- **`flutter_file_upload`** — browser File API cannot be programmatically
  filled from VM Service. Workaround: agent uses HTTP API directly via
  `flutter_evaluate('await Magic.Http.postFile(...)')`.
- **`flutter_resize`** — no Dart-side equivalent yet. Use Chrome devtools
  manually.
- **Hot-restart staleness** — after `R` in flutter run, the CLI's recorded
  startedAt drifts from the live isolate startTime. `doctor` warns when
  delta > 5s; agent restarts CLI for fresh extension table.
- **Wind v1.0.0-alpha.7 Semantics annotations** — relied on for richer
  snapshot YAML labels. Native Flutter widgets get framework-default
  semantics (functional but less verbose).

## References

- Plan: `.ac/plans/ai-test-v3/plan.md` (28 steps, 9 waves)
- Wave 1 spike: `.ac/plans/ai-test-v3/evidence/wave-1-spike.md`
- Walkthrough: `.ac/plans/ai-test-v3/evidence/walkthrough.ts` + readme
- Live run report: `.ac/plans/ai-test-v3/evidence/LIVE_RUN_REPORT.md` (Step 26)
- V1 forensics: `references/ai-test/V1_RESULT.md`
