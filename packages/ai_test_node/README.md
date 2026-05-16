# ai-test-mcp (V3)

Model Context Protocol (MCP) server bridging LLM agents (Claude Desktop, Cursor, custom) to a running Flutter web app via the Dart VM Service Protocol.

V3 = MCP-only single-channel. One `flutter run -d chrome` session, one VM Service WebSocket, 19 tools. No Playwright, no DOM mirror.

Companion to `ai_test_flutter` v3 (Dart plugin + `bin/` CLI). Together they form the V3 architecture.

## Tools (19, post Oracle cull)

| Tool | Underlying RPC | Purpose |
|---|---|---|
| `flutter_navigate` | `ext.aitest.navigate` | MagicRoute.to(route) |
| `flutter_navigate_back` | `ext.aitest.navigate_back` | MagicRoute.back() |
| `flutter_get_routes` | `ext.aitest.get_routes` | Current location + title |
| `flutter_close_app` | vmClient.disconnect (soft) | Detach MCP from running flutter |
| `flutter_resize` | DEFERRED ALPHA | Use Chrome devtools manually |
| `flutter_snapshot` | `ext.aitest.snapshot` | YAML accessibility tree with `[ref=eN]` ids + magicFormField enrichment |
| `flutter_screenshot` | `ext.aitest.screenshot` | base64 JPEG q70 (default) or PNG via RepaintBoundary.toImage |
| `flutter_evaluate` | VM Service `evaluate` RPC | Arbitrary Dart expression vs rootLib (state inspection) |
| `flutter_tap` | `ext.aitest.tap` | Pointer Down + Up at ref's centroid; tap-then-requestKeyboard for text fields |
| `flutter_type` | `ext.aitest.type` | controller.value mutation + endOfFrame x2 |
| `flutter_press_key` | `ext.aitest.press_key` | HardwareKeyboard KeyDown + KeyUp |
| `flutter_hover` | `ext.aitest.hover` | PointerHoverEvent for MouseRegion |
| `flutter_drag` | `ext.aitest.drag` | Down + 5×Move + Up between two refs |
| `flutter_select_option` | `ext.aitest.select_option` | DropdownButton.onChanged invocation |
| `flutter_file_upload` | DEFERRED V3.1 | browser File API not programmatically fillable from VM Service |
| `flutter_wait_for` | `ext.aitest.wait_for` | Poll for text presence/absence/expression with timeout |
| `flutter_network_requests` | `ext.aitest.network_requests` | Last 50 HTTP calls from Dio interceptor ring buffer |
| `flutter_console_messages` | `ext.aitest.console_messages` | Last 100 logs from Logger.root.onRecord ring buffer |
| `flutter_mock_http` | `ext.aitest.mock_http` | Register interceptor short-circuit rule |

**Dropped per Oracle cull**: `flutter_inspect_state`, `flutter_inspect_form`, `flutter_handle_dialog`, `flutter_hot_reload`. State inspection uses the `flutter_evaluate` pattern below; form fields live inside snapshot YAML.

## State inspection pattern

Without dart2js reflection a typed `flutter_inspect_state(controllerName)` would be a fake hint. Use `flutter_evaluate` directly with the explicit class name:

```typescript
await client.callTool({
  name: 'flutter_evaluate',
  arguments: { expression: 'Magic.find<MonitorController>().rxState.value.toString()' },
});
// → { content: [{ type: 'text', text: '<serialized state>' }] }
```

For raw Magic facade reads:

```typescript
{ expression: 'Auth.user()?.email' }
{ expression: 'MagicRouter.instance.currentLocation' }
{ expression: 'Cache.get("monitors", "[]")' }
```

## Install (dev mode)

V3 does not publish to npm. The MCP server runs directly from source via `tsx`:

```bash
cd references/ai-test/packages/ai_test_node
bun install            # or npm install
bun run typecheck      # tsc --noEmit
bun run test           # vitest (73 tests, no live VM Service required)
bun run dev            # boots the server on stdio for manual probing
```

## MCP host config

Add to your MCP client config (Claude Desktop, Cursor, etc.):

```json
{
  "mcpServers": {
    "ai-test": {
      "command": "bun",
      "args": ["x", "tsx", "src/cli.ts"],
      "cwd": "/absolute/path/to/references/ai-test/packages/ai_test_node"
    }
  }
}
```

The server reads the VM Service URI from `~/.ai-test/state.json` (written by the `ai_test_flutter` CLI's `start` command). If absent, falls back to `AI_TEST_VM_SERVICE_URI` env var, otherwise defaults to `ws://127.0.0.1:8181/ws`.

## Operator workflow

```bash
# Terminal 1 — boot the Flutter app
cd /path/to/host/flutter/app
dart run ai_test_flutter:ai_test_flutter start
# → Chrome opens with the app; ~/.ai-test/state.json written.

# Agent (separate process via MCP stdio) now has 19 tools.

# Terminal 1 — when done
dart run ai_test_flutter:ai_test_flutter stop
```

## References

- Architecture: `references/ai-test/V3_OVERVIEW.md`
- Walkthrough: `.ac/plans/ai-test-v3/evidence/walkthrough.ts` + readme
- Plan: `.ac/plans/ai-test-v3/plan.md`
