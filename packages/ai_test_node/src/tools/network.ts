import { z } from 'zod';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import type { LazyVmClient } from '../server.js';

/**
 * Subset of `LazyVmClient` the network/mock tool group depends on. Mirrors the
 * narrow surface used by `navigation.ts` — wrappers stay unaware of the lazy
 * connection machinery (URI discovery, reconnect) they do not own.
 */
type NetworkVmClient = Pick<LazyVmClient, 'call' | 'getMainIsolateId'>;

// ---------------------------------------------------------------------------
// Recognised console-log level names.
//
// Mirrors the `_resolveLevelName` switch in `ext_network_console.dart`. Keeping
// the list as a zod enum gives the agent a discoverable contract and rejects
// typos before the call ever reaches the VM Service.
// ---------------------------------------------------------------------------

const CONSOLE_LEVELS = [
    'all',
    'finest',
    'finer',
    'fine',
    'config',
    'info',
    'warning',
    'error',
    'severe',
    'shout',
] as const;

// ---------------------------------------------------------------------------
// Envelope helpers — identical shape to `navigation.ts` for consistency.
// ---------------------------------------------------------------------------

/**
 * Build a success envelope. The MCP spec only defines `text`, `image`, `audio`,
 * and `resource` content variants — there is no `json` variant — so structured
 * payloads are serialized into a text block and re-parsed by the agent.
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
 * Build a tool-level error envelope. The `isError: true` flag follows the MCP
 * convention for tool-level errors: clients see the failure without the
 * JSON-RPC layer raising a protocol-level exception.
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
 * Register the network + mock tool group (3 tools) on the given MCP server.
 *
 * Tool names registered here MUST match the 3 stub names Step 18 added
 * (`flutter_network_requests`, `flutter_console_messages`, `flutter_mock_http`).
 * The Step 22b aggregator removes the stubs and calls this function instead.
 *
 * Two tools (`flutter_inspect_state`, `flutter_inspect_form`) from the original
 * V3 catalog were culled by Oracle: dart2js has no reflection, and the snapshot
 * already enriches form-field nodes with their `MagicForm` ancestor's field
 * name. Agents use `flutter_evaluate('Magic.find<X>().rxState.value.toString()')`
 * for typed state inspection instead. Do NOT re-introduce them here.
 *
 * @param server   Target MCP server (the one created by `createServer()`).
 * @param vmClient Lazy VM Service client; tests inject a fake matching the
 *                 narrowed `NetworkVmClient` surface.
 */
export function registerNetworkTools(
    server: McpServer,
    vmClient: NetworkVmClient,
): void {
    registerFlutterNetworkRequests(server, vmClient);
    registerFlutterConsoleMessages(server, vmClient);
    registerFlutterMockHttp(server, vmClient);
}

// ---------------------------------------------------------------------------
// flutter_network_requests
// ---------------------------------------------------------------------------

/**
 * `flutter_network_requests({limit?, filter?})` →
 *   `ext.aitest.network_requests({isolateId, limit?, filter?})`.
 *
 * The Dart-side handler reads the [AiTestHttpInterceptor] ring buffer and
 * returns `{requests: [...]}`. Whenever the interceptor was never registered
 * (or the buffer is empty), the Dart side still answers with `{requests: []}`;
 * we defensively coerce a missing `requests` key to an empty list so the agent
 * never sees `undefined` for that field.
 *
 * `limit` is serialized as a string because VM Service ServiceExtension params
 * are `Map<String, String>` on the Dart side (the protocol auto-stringifies
 * primitives, but explicit stringification keeps the contract obvious).
 */
function registerFlutterNetworkRequests(
    server: McpServer,
    vmClient: NetworkVmClient,
): void {
    server.registerTool(
        'flutter_network_requests',
        {
            description:
                'Return the list of HTTP requests the app has issued since boot. Wraps `ext.aitest.network_requests` reading the AiTestHttpInterceptor ring buffer (most recent 50).',
            inputSchema: {
                limit: z
                    .coerce.number()
                    .int('limit must be an integer')
                    .positive('limit must be a positive integer')
                    .optional(),
                filter: z
                    .string()
                    .min(1, 'filter must be a non-empty URL substring')
                    .optional(),
            },
        },
        async ({ limit, filter }): Promise<CallToolResult> => {
            try {
                const isolateId = await vmClient.getMainIsolateId();
                const params: Record<string, string> = { isolateId };
                if (limit !== undefined) params.limit = String(limit);
                if (filter !== undefined) params.filter = filter;
                const result = await vmClient.call<{
                    requests?: ReadonlyArray<unknown>;
                }>('ext.aitest.network_requests', params);
                // Defensive: coerce missing key to empty array (per briefing
                // "return empty array gracefully" when interceptor absent).
                return ok({ requests: result.requests ?? [] });
            } catch (err) {
                return fail(`flutter_network_requests: ${describeError(err)}`);
            }
        },
    );
}

// ---------------------------------------------------------------------------
// flutter_console_messages
// ---------------------------------------------------------------------------

/**
 * `flutter_console_messages({limit?, level?})` →
 *   `ext.aitest.console_messages({isolateId, limit?, level?})`.
 *
 * The Dart-side handler reads the [AiTestLogSink] ring buffer and returns
 * `{messages: [...]}`. The accepted `level` names mirror the Dart-side
 * `_resolveLevelName` switch and are restricted via zod enum so typos surface
 * before the call ever reaches the VM Service.
 */
function registerFlutterConsoleMessages(
    server: McpServer,
    vmClient: NetworkVmClient,
): void {
    server.registerTool(
        'flutter_console_messages',
        {
            description:
                'Return the list of console log entries the app has emitted since boot. Wraps `ext.aitest.console_messages` reading the AiTestLogSink ring buffer (most recent 100). Accepted level names: all, finest, finer, fine, config, info, warning, error, severe, shout.',
            inputSchema: {
                limit: z
                    .coerce.number()
                    .int('limit must be an integer')
                    .positive('limit must be a positive integer')
                    .optional(),
                level: z.enum(CONSOLE_LEVELS).optional(),
            },
        },
        async ({ limit, level }): Promise<CallToolResult> => {
            try {
                const isolateId = await vmClient.getMainIsolateId();
                const params: Record<string, string> = { isolateId };
                if (limit !== undefined) params.limit = String(limit);
                if (level !== undefined) params.level = level;
                const result = await vmClient.call<{
                    messages?: ReadonlyArray<unknown>;
                }>('ext.aitest.console_messages', params);
                return ok({ messages: result.messages ?? [] });
            } catch (err) {
                return fail(`flutter_console_messages: ${describeError(err)}`);
            }
        },
    );
}

// ---------------------------------------------------------------------------
// flutter_mock_http
// ---------------------------------------------------------------------------

/**
 * `flutter_mock_http({pattern, status, body, contentType?, headers?})` →
 *   `ext.aitest.mock_http({isolateId, pattern, status, body, contentType?, headers?})`.
 *
 * Registers a single mock-HTTP rule against [AiTestHttpInterceptor]. The Dart
 * handler returns `{ok: true, pattern}`. Param normalization details:
 *
 * 1. `status` (HTTP status code, 100-599) is stringified — the Dart side
 *    int.tryParses it back.
 * 2. `headers` is JSON-encoded — the Dart side jsonDecodes it back into
 *    `Map<String, String>` because ServiceExtension params cannot carry nested
 *    structures.
 * 3. `body` is REQUIRED at the MCP layer even though the Dart side defaults to
 *    empty string when absent — explicit empty string surfaces agent intent.
 */
function registerFlutterMockHttp(
    server: McpServer,
    vmClient: NetworkVmClient,
): void {
    server.registerTool(
        'flutter_mock_http',
        {
            description:
                'Install an HTTP mock for the given URL substring/pattern. Subsequent `Http` facade calls matching `pattern` short-circuit with the canned response instead of hitting the network. Rules reset on hot-restart.',
            inputSchema: {
                pattern: z
                    .string()
                    .min(1, 'pattern must be a non-empty URL substring or regex'),
                status: z
                    .coerce.number()
                    .int('status must be an integer HTTP status code')
                    .min(100, 'status must be a valid HTTP status code (>= 100)')
                    .max(599, 'status must be a valid HTTP status code (<= 599)'),
                body: z.string(),
                contentType: z.string().min(1).optional(),
                headers: z.record(z.string(), z.string()).optional(),
            },
        },
        async ({
            pattern,
            status,
            body,
            contentType,
            headers,
        }): Promise<CallToolResult> => {
            try {
                const isolateId = await vmClient.getMainIsolateId();
                // 1. Stringify numeric status — ServiceExtension params are
                //    Map<String,String>; the Dart handler int.tryParses back.
                const params: Record<string, string> = {
                    isolateId,
                    pattern,
                    status: String(status),
                    body,
                };
                // 2. Optional contentType passes through verbatim.
                if (contentType !== undefined) params.contentType = contentType;
                // 3. Headers map → JSON string so the Dart handler can
                //    jsonDecode back into Map<String,String>.
                if (headers !== undefined) params.headers = JSON.stringify(headers);
                const result = await vmClient.call<unknown>(
                    'ext.aitest.mock_http',
                    params,
                );
                return ok(result);
            } catch (err) {
                return fail(`flutter_mock_http: ${describeError(err)}`);
            }
        },
    );
}
