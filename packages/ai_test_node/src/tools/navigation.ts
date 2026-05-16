import { z } from 'zod';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import type { LazyVmClient } from '../server.js';

/**
 * Subset of `LazyVmClient` the Wave 6 tool wrappers actually depend on. Tests
 * pass a fake matching this shape; production wires the full `LazyVmClient` via
 * `createServer(vmClient)`. Narrowing here keeps the wrapper unaware of the
 * lazy-connection machinery (URI discovery, reconnect) it does not control.
 */
type NavigationVmClient = Pick<
    LazyVmClient,
    'call' | 'disconnect' | 'getMainIsolateId'
>;

/**
 * Build a success envelope. The MCP spec only defines `text`, `image`, `audio`,
 * and `resource` content variants — there is no `json` variant — so structured
 * payloads are serialized into a text block and re-parsed by the agent.
 *
 * @param payload Arbitrary structured value that round-trips through JSON.
 */
function ok(payload: unknown): CallToolResult {
    return {
        content: [
            {
                type: 'text',
                text: JSON.stringify(payload),
            },
        ],
    };
}

/**
 * Build a tool-level error envelope. We intentionally do NOT throw `McpError`
 * here — the briefing for Step 19 specifies the `{isError: true, content: [...]}`
 * shape so agents see the failure without a JSON-RPC protocol-level fault.
 *
 * @param message Human-readable failure reason; surfaced verbatim to the agent.
 */
function fail(message: string): CallToolResult {
    return {
        isError: true,
        content: [
            {
                type: 'text',
                text: message,
            },
        ],
    };
}

/**
 * Translate any thrown value into a stable string for the `fail()` envelope.
 * Preserves `Error.message`; falls back to `String(err)` for everything else
 * (preserves `VmServiceError.message` because it `extends Error`).
 */
function describeError(err: unknown): string {
    if (err instanceof Error) return err.message;
    return String(err);
}

/**
 * Register the navigation + lifecycle tool group (5 tools) on the given MCP
 * server. This is the wrapper-design pattern Steps 20-22 will follow:
 *
 *   1. Each tool's `inputSchema` is a strict `z.ZodRawShape` matching the
 *      `ext.aitest.<name>` Dart-side handler signature exactly (no extras).
 *   2. Handlers resolve the isolate id via `vmClient.getMainIsolateId()` and
 *      forward `{isolateId, ...args}` to `vmClient.call('ext.aitest.<name>')`.
 *   3. Success → `ok(rawResult)`; thrown → `fail(message)` envelope.
 *
 * The 5 names registered here MUST match the 5 stub names Step 18 added
 * (`flutter_navigate`, `flutter_navigate_back`, `flutter_close_app`,
 * `flutter_resize`, `flutter_get_routes`) — the Step 22b aggregator removes
 * the stubs and calls this function instead.
 *
 * @param server  Target MCP server (the one created by `createServer()`).
 * @param vmClient Lazy VM Service client; tests inject a fake matching the
 *                 narrowed `NavigationVmClient` surface.
 */
export function registerNavigationTools(
    server: McpServer,
    vmClient: NavigationVmClient,
): void {
    registerFlutterNavigate(server, vmClient);
    registerFlutterNavigateBack(server, vmClient);
    registerFlutterGetRoutes(server, vmClient);
    registerFlutterCloseApp(server, vmClient);
    registerFlutterResize(server);
}

// ---------------------------------------------------------------------------
// Individual tool registrations
// ---------------------------------------------------------------------------

/**
 * `flutter_navigate({route})` → `ext.aitest.navigate({isolateId, route})`.
 *
 * Dart-side handler expects a non-empty `route` param; the MCP layer enforces
 * the same constraint so the call never reaches the VM Service with a value
 * the handler is guaranteed to reject.
 */
function registerFlutterNavigate(
    server: McpServer,
    vmClient: NavigationVmClient,
): void {
    server.registerTool(
        'flutter_navigate',
        {
            description:
                'Push a named or path route on the running app. Equivalent to `MagicRoute.to(<path>)` on the Dart side.',
            inputSchema: {
                route: z
                    .string()
                    .min(1, 'route must be a non-empty path, e.g. "/dashboard"'),
            },
        },
        async ({ route }): Promise<CallToolResult> => {
            try {
                const isolateId = await vmClient.getMainIsolateId();
                const result = await vmClient.call<unknown>('ext.aitest.navigate', {
                    isolateId,
                    route,
                });
                return ok(result);
            } catch (err) {
                return fail(`flutter_navigate: ${describeError(err)}`);
            }
        },
    );
}

/**
 * `flutter_navigate_back()` → `ext.aitest.navigate_back({isolateId})`.
 */
function registerFlutterNavigateBack(
    server: McpServer,
    vmClient: NavigationVmClient,
): void {
    server.registerTool(
        'flutter_navigate_back',
        {
            description:
                'Pop the topmost route. Equivalent to `MagicRoute.back()` on the Dart side.',
            inputSchema: {},
        },
        async (): Promise<CallToolResult> => {
            try {
                const isolateId = await vmClient.getMainIsolateId();
                const result = await vmClient.call<unknown>(
                    'ext.aitest.navigate_back',
                    {
                        isolateId,
                    },
                );
                return ok(result);
            } catch (err) {
                return fail(`flutter_navigate_back: ${describeError(err)}`);
            }
        },
    );
}

/**
 * `flutter_get_routes()` → `ext.aitest.get_routes({isolateId})`.
 *
 * Returns `{location, title}` from the Dart-side `MagicRouter.instance`.
 */
function registerFlutterGetRoutes(
    server: McpServer,
    vmClient: NavigationVmClient,
): void {
    server.registerTool(
        'flutter_get_routes',
        {
            description:
                'Return the current GoRouter location and page title. Use after navigation to verify the route changed.',
            inputSchema: {},
        },
        async (): Promise<CallToolResult> => {
            try {
                const isolateId = await vmClient.getMainIsolateId();
                const result = await vmClient.call<unknown>(
                    'ext.aitest.get_routes',
                    {
                        isolateId,
                    },
                );
                return ok(result);
            } catch (err) {
                return fail(`flutter_get_routes: ${describeError(err)}`);
            }
        },
    );
}

/**
 * `flutter_close_app()` — soft-close, client-side only.
 *
 * No `ext.aitest.close_app` extension exists on the Dart side (the Flutter web
 * runtime has no clean teardown hook short of closing the tab). The tool is
 * kept in the catalog so agents can express the intent "I am done with this
 * scenario"; the implementation tears down the MCP server's VM Service
 * connection. Operators or test runners are responsible for restarting the
 * Flutter app to actually reset in-memory state.
 *
 * Deviation tracked in Step 19 report: "soft-close via vmClient.disconnect"
 * vs. the briefing's two-option suggestion.
 */
function registerFlutterCloseApp(
    server: McpServer,
    vmClient: NavigationVmClient,
): void {
    server.registerTool(
        'flutter_close_app',
        {
            description:
                'Tear down the MCP-side VM Service connection. Note: this does NOT stop the Flutter app itself; restart the launch script to reset in-memory state.',
            inputSchema: {},
        },
        async (): Promise<CallToolResult> => {
            try {
                await vmClient.disconnect();
                return ok({ closed: true });
            } catch (err) {
                return fail(`flutter_close_app: ${describeError(err)}`);
            }
        },
    );
}

/**
 * `flutter_resize({width, height})` — phase-ALPHA stub.
 *
 * No matching Dart-side extension exists yet (the V3 ALPHA scope does not
 * include viewport-resize plumbing). The tool registration is preserved so the
 * agent can discover the gap explicitly through `tools/list`; calling it
 * returns an `isError` envelope explaining the limitation instead of silently
 * succeeding.
 *
 * Wire to `ext.aitest.resize` once that extension lands (tracked in V3.1).
 */
function registerFlutterResize(server: McpServer): void {
    server.registerTool(
        'flutter_resize',
        {
            description:
                'Resize the Flutter viewport. Width and height in logical pixels. Phase ALPHA: not yet implemented; use Chrome devtools for now.',
            inputSchema: {
                width: z.coerce.number().positive(),
                height: z.coerce.number().positive(),
            },
        },
        async (): Promise<CallToolResult> => {
            return fail(
                'flutter_resize not yet implemented; use Chrome devtools to resize the viewport.',
            );
        },
    );
}
