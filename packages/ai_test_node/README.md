# ai-test-mcp

Model Context Protocol (MCP) server bridging LLM agents (Claude Desktop, Cursor,
etc.) to a running Flutter Web app via the Dart VM Service Protocol.

Companion to `ai_test_flutter` v2 (Dart plugin) and `playwright-cli` (web spec
runner). Together these form the Hybrid B+C architecture: Flutter's native
Semantics tree as the primary selector surface, the VM Service as the structured
state inspection fallback.

## Tools

| Tool              | Underlying RPC                            | Purpose                                                          |
|-------------------|-------------------------------------------|------------------------------------------------------------------|
| `get_widget_tree` | `ext.flutter.inspector.getRootWidgetTree` | Full Flutter widget tree (type, key, props, bounding boxes).     |
| `evaluate_dart`   | `evaluate`                                | Run a Dart expression scoped to `main.dart`. Magic.find, Auth, … |
| `get_routes`      | `ext.aitest.getRoutes`                    | Current GoRouter location + page title.                          |

## Install (dev mode)

V2 does not publish to npm. The MCP server runs directly from source via `tsx`:

```bash
cd references/ai-test/packages/ai_test_node
bun install                # or `npm install`
bun run typecheck          # verify
bun run test               # vitest, no live VM Service required
bun run dev                # boots the server on stdio for manual probing
```

## Environment

| Variable                   | Default                  | Purpose                                                 |
|----------------------------|--------------------------|---------------------------------------------------------|
| `AI_TEST_VM_SERVICE_URI`   | `ws://127.0.0.1:8181/ws` | WebSocket endpoint of the Flutter app's VM Service.     |

The default matches a Flutter app launched with:

```bash
flutter run -d chrome --web-port=3100 \
  --enable-vm-service --disable-service-auth-codes
```

If you run with auth codes enabled, copy the URI from the launcher's stdout
(e.g. `ws://127.0.0.1:8181/<token>/ws`) and export it as
`AI_TEST_VM_SERVICE_URI`.

## MCP Client Configuration

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "ai-test": {
      "command": "npx",
      "args": [
        "tsx",
        "/absolute/path/to/uptizm-app/references/ai-test/packages/ai_test_node/src/index.ts"
      ],
      "env": {
        "AI_TEST_VM_SERVICE_URI": "ws://127.0.0.1:8181/ws"
      }
    }
  }
}
```

### Cursor

`Settings → Tools & Integrations → MCP Servers → Edit Config`:

```json
{
  "mcpServers": {
    "ai-test": {
      "command": "npx",
      "args": [
        "tsx",
        "/absolute/path/to/uptizm-app/references/ai-test/packages/ai_test_node/src/index.ts"
      ]
    }
  }
}
```

After saving, restart the host. The three tools (`get_widget_tree`,
`evaluate_dart`, `get_routes`) appear under the `ai-test` server entry.

## Architecture Notes

- Transport: stdio only (V2 scope). HTTP transport is deliberately out of scope.
- WebSocket: `ws` library; one connection per server lifetime, lazily opened on
  first tool call. Pending requests are rejected with `VmServiceError` if the
  socket closes mid-flight.
- Tool input validation: `zod`. Invalid input surfaces as `McpError` with
  `code: -32602` (InvalidParams).
- Tool runtime errors: `VmServiceError` from the client is translated to
  `McpError` with `code: -32000` (ConnectionClosed / server error).
- Caching: the `evaluate_dart` tool resolves the isolate's root library id
  once via `getIsolate` and caches it per session so subsequent expressions
  share the same Dart scope as `package:<app>/main.dart`.

## Layout

```
src/
├── index.ts              # MCP server entry; stdio transport; lazy VM client
├── types.ts              # Shared TypeScript types (VM Service shapes)
├── vm_service_client.ts  # ws-based JSON-RPC 2.0 client
└── tools/
    ├── index.ts          # Barrel + registerAll(server, vmClient)
    ├── get_widget_tree.ts
    ├── evaluate_dart.ts
    └── get_routes.ts
test/
├── vm_service_client.test.ts  # ws-based fake VM Service
└── tools.test.ts              # mocked ToolContext per tool
```

## Limitations

- No HTTP transport (stdio only).
- No auto-reconnect after VM Service drops; the next tool call attempts a fresh
  connect, so a restarted Flutter app recovers without an MCP host restart.
- Single isolate only (web apps; main isolate is the only one).
