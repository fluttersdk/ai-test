# ai-test — Flutter Web LLM-Agent Control

Two packages bridge a running Flutter web app to an LLM coding agent (Claude / Cursor / similar) so the agent can drive, inspect, and verify the app via Playwright.

| Package | Path | Role |
|---|---|---|
| `ai_test_flutter` | `packages/ai_test_flutter/` | Tiny Dart plugin: enables Flutter Semantics tree, exposes `window.__aiTestReady`, registers `ext.aitest.getRoutes` VM Service extension |
| `ai_test_node` | `packages/ai_test_node/` | TypeScript MCP server bridging an LLM agent to the Dart VM Service (3 tools: `get_widget_tree`, `evaluate_dart`, `get_routes`) |

## V2 Architecture: Hybrid B+C

Native Flutter Semantics tree (primary selector surface for Playwright) + VM Service Inspector Protocol (fallback for state inspection beyond what Semantics surfaces).

**Why Hybrid B+C:**
- Semantics is Flutter's source-of-truth for "what does this widget mean"; covers Material primitives + the in-house Wind framework's interactive widgets (`WAnchor`, `WButton`, `WInput`, `WFormInput`, `WCheckbox`, `WSelect`, `WDatePicker`).
- After Flutter PR #39688 (Mar 2023) `flt-semantics` lives in plain LIGHT DOM, so Playwright's `getByRole`, `getByLabel`, `getByText` resolve without shadow piercing.
- VM Service exposes the structured widget tree + arbitrary Dart `evaluate` for the cases Semantics cannot reach (controller state, MagicFormData values, route snapshots).

V0 used a parallel `<div>` mirror DOM projection; V1 hardened it; V2 abandoned the parallel-tree approach in favor of Flutter native Semantics + VM Service. Forensics: `V1_RESULT.md`.

## Launch

From the consumer Flutter app's repo:

```sh
scripts/dev-with-aitest.sh
```

Boots Flutter web on `http://127.0.0.1:3100` with VM Service WebSocket exposed at `ws://127.0.0.1:8181/ws` (auth disabled for local dev). The plugin's `RendererBinding.instance.ensureSemantics()` runs inside a `kIsWeb && kDebugMode + AI_TEST=1` gate; production builds tree-shake the entire branch out.

## How an LLM agent drives the app

Two surfaces, used together:

### 1. Playwright (browser-side)

Helpers in `references/playwright-cli/tests/_helpers.ts`:

| Helper | Purpose |
|---|---|
| `loginViaSemantics(page, { email, password })` | Navigate, wait for ready, fill email + password by aria-label / placeholder, click sign-in by role |
| `clickByName(page, name, role?)` | `page.getByRole(role ?? 'button', { name }).click()` with coordinate fallback |
| `fillByLabel(page, label, value)` | `page.getByLabel(label).fill(value)` |
| `waitForFlutterReady(page)` | Wait for `flt-glass-pane` + 800ms CanvasKit init + `window.__aiTestReady === true` |
| `clickByCoordinate(page, locator)` | Escape-hatch when target widget does NOT emit Semantics (raw `CustomPainter` / bare `GestureDetector`) |

### 2. MCP server (state-inspection surface)

`packages/ai_test_node/` exposes 3 tools over stdio:

| Tool | Calls | Purpose |
|---|---|---|
| `get_widget_tree` | `ext.flutter.inspector.getRootWidgetTree` | Structured widget tree as JSON; agent discovers what's on screen |
| `evaluate_dart` | VM Service `evaluate` against `main.dart` rootLib | Run arbitrary Dart expressions like `Magic.find<MonitorController>().rxState.value`, `MagicRoute.currentLocation` |
| `get_routes` | `ext.aitest.getRoutes` | Current GoRouter location + page title |

MCP config snippet for Claude Desktop / Cursor:

```json
{
  "mcpServers": {
    "ai-test": {
      "command": "npx",
      "args": ["tsx", "<abs path>/references/ai-test/packages/ai_test_node/src/index.ts"],
      "env": { "AI_TEST_VM_SERVICE_URI": "ws://127.0.0.1:8181/ws" }
    }
  }
}
```

## End-to-end agent walkthrough

Canonical example: `references/playwright-cli/tests/uptizm-agent-walkthrough.spec.ts`. The spec demonstrates the full flow:

1. `loginViaSemantics` (Playwright + Wind Semantics)
2. Navigate to a route, `waitForFlutterReady`
3. MCP `get_widget_tree` to discover what's there
4. MCP `get_routes` to verify navigation
5. `clickByName` (Playwright + Semantics role match)
6. MCP `evaluate_dart` to inspect controller / route state
7. Re-check route to confirm side-effects

## V1 forensics

V1 (Shadow DOM Projection) results: `V1_RESULT.md`. Verdict: NEEDS_WORK / lean ABANDON for the diff approach; recommended pivot to Hybrid B+C, which is V2.
