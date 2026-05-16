import { z } from 'zod';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';

import type { LazyVmClient } from '../server.js';
import { makeToolContext, type ToolContext } from './index.js';
import type { EvaluateResult } from '../types.js';

/**
 * MCP tool wrappers — Wave 6 Group 3 (Step 21 of the V3 plan).
 *
 * Implements 4 self-registering tools:
 *
 * | Tool                  | Backing extension          | Returns                |
 * |-----------------------|----------------------------|------------------------|
 * | `flutter_snapshot`    | `ext.aitest.snapshot`      | YAML text (Playwright-MCP shape) |
 * | `flutter_screenshot`  | `ext.aitest.screenshot`    | base64 image content + mimeType  |
 * | `flutter_evaluate`    | VM Service `evaluate` RPC  | JSON-stringified `@Instance`     |
 * | `flutter_wait_for`    | `ext.aitest.wait_for`      | JSON-stringified `{matched, ...}`|
 * | `flutter_wait_for_request` | `ext.aitest.wait_for_request` | JSON `{matched, url, method, statusCode, durationMs, timestamp}` |
 *
 * `flutter_evaluate` carries forward the V2 `evaluate_dart` semantics
 * (rootLib-scoped evaluation against the running isolate). It is registered
 * here — not in the legacy `evaluate_dart.ts` — so the V3 catalog has a single
 * registration site per tool group. The legacy file is removed in the same
 * change-set; no V2 callers remain.
 *
 * # Self-registration contract
 *
 * The aggregator (Step 22b) calls [registerSnapshotTools] from
 * `createServer()` together with the other three Wave 6 register functions.
 * Each Wave 6 module owns its own `server.registerTool()` calls; the
 * aggregator does no per-tool plumbing.
 *
 * # Error handling
 *
 * Every wrapper returns an MCP `isError: true` envelope on failure (per
 * `research/librarian-mcp-sdk-cli-design.md` Section B). Throws are reserved
 * for protocol-level faults — unexpected errors bubble up and the SDK
 * converts them to envelopes without our message, which is the worse UX.
 *
 * # Parameter coercion (string-typed VM Service extensions)
 *
 * `developer.registerExtension` on the Dart side hands handlers a
 * `Map<String, String>` — every value reaches Dart as a string. The MCP
 * input schemas accept native types (`number`, `boolean`) for ergonomics,
 * but the call-site helpers in this file coerce non-string scalars to
 * strings before delegating to `ext.aitest.*`. The native VM Service
 * `evaluate` RPC accepts mixed types; only `ext.aitest.*` calls go through
 * coercion.
 */

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/**
 * Register the four Group 3 tools on [server], wiring each handler against
 * [vmClient]. Idempotency is not required — `createServer()` calls each
 * `register*Tools` exactly once per process lifetime; the underlying
 * `McpServer.registerTool` throws on duplicate names which we treat as a
 * programmer error rather than a hot path.
 *
 * @param server The `McpServer` instance built by `createServer()`.
 * @param vmClient The lazy VM Service proxy whose `call` / isolate helpers
 *     the tool handlers borrow under closure.
 */
export function registerSnapshotTools(
    server: McpServer,
    vmClient: LazyVmClient,
): void {
    const ctx: ToolContext = makeToolContext(vmClient);

    registerSnapshotTool(server, ctx);
    registerScreenshotTool(server, ctx);
    registerEvaluateTool(server, ctx);
    registerWaitForTool(server, ctx);
    registerWaitForRequestTool(server, ctx);
}

// ---------------------------------------------------------------------------
// flutter_snapshot
// ---------------------------------------------------------------------------

/**
 * Wire dock for `flutter_snapshot`. Calls `ext.aitest.snapshot`, drops the
 * `groupId` from the wire envelope (the agent does not consume it — ref
 * disposal is Dart-side bookkeeping), and forwards the YAML string as a
 * single text content block.
 */
function registerSnapshotTool(server: McpServer, ctx: ToolContext): void {
    server.registerTool(
        'flutter_snapshot',
        {
            description:
                'Capture a structured YAML snapshot of the current widget tree. Returned `ref` tokens feed every interaction tool (`flutter_tap`, `flutter_type`, ...).',
            inputSchema: {
                depth: z
                    .coerce.number()
                    .int()
                    .positive()
                    .optional()
                    .describe(
                        'Optional max tree depth. Omit to walk the whole semantics tree.',
                    ),
            },
            annotations: { readOnlyHint: true },
        },
        async (args): Promise<CallToolResult> => {
            try {
                const isolateId = await ctx.getIsolateId();
                const params = stringifyExtParams({
                    isolateId,
                    depth: args.depth,
                });
                const response = await ctx.call<{
                    snapshot: string;
                    groupId: string;
                }>('ext.aitest.snapshot', params);
                return {
                    content: [{ type: 'text', text: response.snapshot }],
                };
            } catch (err) {
                return errorEnvelope('flutter_snapshot', err);
            }
        },
    );
}

// ---------------------------------------------------------------------------
// flutter_screenshot
// ---------------------------------------------------------------------------

/**
 * Wire dock for `flutter_screenshot`. Calls `ext.aitest.screenshot`, picks
 * the mimeType from the response `format` field (never the input — the
 * Dart side normalises and may downgrade unknown formats), and returns the
 * base64 data verbatim. Width/height metadata is intentionally dropped: the
 * MCP image content variant has no slot for dimensions, and re-wrapping the
 * payload in a multi-block envelope (image + text JSON of dimensions) would
 * confuse downstream multimodal consumers.
 */
function registerScreenshotTool(server: McpServer, ctx: ToolContext): void {
    server.registerTool(
        'flutter_screenshot',
        {
            description:
                'Capture a PNG (default) or JPEG of the running app viewport. Returned as base64 image content; agents can compare against fixtures or feed to multimodal reasoning.',
            inputSchema: {
                ref: z
                    .string()
                    .optional()
                    .describe(
                        'Optional ref from a prior `flutter_snapshot`; falls back to whole-screen capture.',
                    ),
                rect: z
                    .string()
                    .regex(
                        /^\d+(\.\d+)?,\d+(\.\d+)?,\d+(\.\d+)?,\d+(\.\d+)?$/,
                        'rect must be `x,y,w,h` (logical pixels, non-negative numbers).',
                    )
                    .optional()
                    .describe(
                        'Optional `x,y,w,h` sub-rect (logical pixels) relative to the `ref` widget\'s paint bounds. Requires `ref`; rect-only calls are rejected Dart-side.',
                    ),
                format: z
                    .enum(['png', 'jpeg'])
                    .optional()
                    .describe('Image format. Defaults to jpeg on the Dart side.'),
                quality: z
                    .coerce.number()
                    .int()
                    .min(1)
                    .max(100)
                    .optional()
                    .describe('JPEG quality 1-100. Ignored for PNG.'),
            },
            annotations: { readOnlyHint: true },
        },
        async (args): Promise<CallToolResult> => {
            try {
                const isolateId = await ctx.getIsolateId();
                const params = stringifyExtParams({
                    isolateId,
                    ref: args.ref,
                    rect: args.rect,
                    format: args.format,
                    quality: args.quality,
                });
                const response = await ctx.call<{
                    format: 'png' | 'jpeg' | string;
                    base64: string;
                    width: number;
                    height: number;
                }>('ext.aitest.screenshot', params);

                const mimeType =
                    response.format === 'jpeg' ? 'image/jpeg' : 'image/png';

                return {
                    content: [
                        {
                            type: 'image',
                            mimeType,
                            data: response.base64,
                        },
                    ],
                };
            } catch (err) {
                return errorEnvelope('flutter_screenshot', err);
            }
        },
    );
}

// ---------------------------------------------------------------------------
// flutter_evaluate
// ---------------------------------------------------------------------------

/**
 * Wire dock for `flutter_evaluate` (V2 carry-over).
 *
 * Runs an arbitrary Dart expression against the root library of the running
 * isolate (`main.dart` scope, so `Magic.find<T>()`, `MagicRoute.currentLocation`,
 * etc. resolve naturally). The `targetId` is resolved once via the cached
 * `getRootLibId` on the lazy client — Step 17 / V2 lift keeps the cache at
 * the `VmServiceClient` layer so a hot-restart-driven isolate swap clears it.
 *
 * The response is the raw `@Instance` envelope from the VM Service: agents
 * read `valueAsString` for primitives, walk `fields` for object inspection.
 * We JSON-stringify into a single text content block; structured returns
 * have no native MCP slot.
 */
function registerEvaluateTool(server: McpServer, ctx: ToolContext): void {
    server.registerTool(
        'flutter_evaluate',
        {
            description:
                'Run a Dart expression inside the running app (scoped to the root library). Use for state inspection beyond the widget tree, e.g. `Magic.find<MonitorController>().rxState.value` or `Auth.user()?.email`.',
            inputSchema: {
                expression: z
                    .string()
                    .min(1, 'expression must be a non-empty Dart source fragment')
                    .describe(
                        'Dart expression to evaluate inside the running app, e.g. "1 + 1".',
                    ),
            },
            annotations: { readOnlyHint: true },
        },
        async (args): Promise<CallToolResult> => {
            try {
                const isolateId = await ctx.getIsolateId();
                const targetId = await ctx.getRootLibId(isolateId);
                const result = await ctx.call<EvaluateResult>('evaluate', {
                    isolateId,
                    targetId,
                    expression: args.expression,
                });
                return {
                    content: [{ type: 'text', text: JSON.stringify(result) }],
                };
            } catch (err) {
                return errorEnvelope('flutter_evaluate', err);
            }
        },
    );
}

// ---------------------------------------------------------------------------
// flutter_wait_for
// ---------------------------------------------------------------------------

/**
 * Wire dock for `flutter_wait_for`. Pass-through to `ext.aitest.wait_for`.
 * Returns the Dart-side envelope (`{matched, elapsedMs}` on success,
 * `{matched: false, reason}` on timeout) verbatim as JSON text so agents
 * can branch on `matched` directly.
 *
 * Predicate priority is enforced Dart-side: when more than one of
 * `text` / `textGone` / `expression` is set, the Dart handler picks the
 * first non-null in that order. Wrapper does not pre-validate to keep the
 * surface thin and the responsibility single-sourced.
 */
function registerWaitForTool(server: McpServer, ctx: ToolContext): void {
    server.registerTool(
        'flutter_wait_for',
        {
            description:
                'Wait until a text predicate matches (or vanishes for `textGone`) or the timeout elapses. Polls every ~200ms on the Dart side.',
            inputSchema: {
                text: z
                    .string()
                    .optional()
                    .describe('Wait until a Text widget with this data appears.'),
                textGone: z
                    .string()
                    .optional()
                    .describe(
                        'Wait until a Text widget with this data disappears from the tree.',
                    ),
                expression: z
                    .string()
                    .optional()
                    .describe(
                        'Free-form predicate (currently treated as text-presence on the Dart side).',
                    ),
                timeoutMs: z
                    .coerce.number()
                    .int()
                    .positive()
                    .optional()
                    .describe(
                        'Timeout in milliseconds. Defaults to 5000 Dart-side. ' +
                            'Coerces string values (some agents send numbers as JSON strings).',
                    ),
            },
            annotations: { readOnlyHint: true },
        },
        async (args): Promise<CallToolResult> => {
            try {
                const isolateId = await ctx.getIsolateId();
                const params = stringifyExtParams({
                    isolateId,
                    text: args.text,
                    textGone: args.textGone,
                    expression: args.expression,
                    timeoutMs: args.timeoutMs,
                });
                const response = await ctx.call<Record<string, unknown>>(
                    'ext.aitest.wait_for',
                    params,
                );
                return {
                    content: [{ type: 'text', text: JSON.stringify(response) }],
                };
            } catch (err) {
                return errorEnvelope('flutter_wait_for', err);
            }
        },
    );
}

// ---------------------------------------------------------------------------
// flutter_wait_for_request
// ---------------------------------------------------------------------------

/**
 * Wire dock for `flutter_wait_for_request`. Pass-through to
 * `ext.aitest.wait_for_request`. Returns the Dart-side envelope verbatim as
 * JSON text so agents can branch on `matched` directly without parsing
 * nested structures.
 *
 * The Dart handler runs a two-phase match:
 * 1. Scan the existing HTTP ring buffer (50 most recent) for an entry that
 *    already satisfies the predicate — agents may call this AFTER the
 *    network round-trip completed.
 * 2. If no buffered match, subscribe to the broadcast stream and wait up to
 *    `timeoutMs` for the next satisfying entry.
 *
 * No client-side polling: the subscribe-or-scan happens Dart-side so the
 * agent pays a single RPC round-trip regardless of when the request lands.
 */
function registerWaitForRequestTool(server: McpServer, ctx: ToolContext): void {
    server.registerTool(
        'flutter_wait_for_request',
        {
            description:
                'Wait until an HTTP request captured by the in-app interceptor matches the given URL/method/status predicate, or the timeout elapses. Scans the recent buffer first, then subscribes to new entries — agents call this both before and after the round-trip without a race.',
            inputSchema: {
                urlPattern: z
                    .string()
                    .min(1, 'urlPattern must be a non-empty regex')
                    .describe(
                        'Regex matched against the request URL (e.g. "/monitors/\\\\d+/metrics"). Bare strings work because regex literal characters match themselves.',
                    ),
                method: z
                    .string()
                    .optional()
                    .describe(
                        'Optional exact HTTP method filter (case-insensitive): GET, POST, PATCH, DELETE, ...',
                    ),
                minStatus: z
                    .coerce.number()
                    .int()
                    .optional()
                    .describe(
                        'Optional inclusive lower bound for statusCode. Omit to accept any status.',
                    ),
                maxStatus: z
                    .coerce.number()
                    .int()
                    .optional()
                    .describe(
                        'Optional inclusive upper bound for statusCode. Pair with minStatus for ranges like 200-299 or 400-499.',
                    ),
                timeoutMs: z
                    .coerce.number()
                    .int()
                    .positive()
                    .default(5000)
                    .describe(
                        'Timeout in milliseconds. Defaults to 5000. Coerces string values (some agents send numbers as JSON strings).',
                    ),
            },
            annotations: { readOnlyHint: true },
        },
        async (args): Promise<CallToolResult> => {
            try {
                const isolateId = await ctx.getIsolateId();
                const params = stringifyExtParams({
                    isolateId,
                    urlPattern: args.urlPattern,
                    method: args.method,
                    minStatus: args.minStatus,
                    maxStatus: args.maxStatus,
                    timeoutMs: args.timeoutMs,
                });
                const response = await ctx.call<Record<string, unknown>>(
                    'ext.aitest.wait_for_request',
                    params,
                );
                return {
                    content: [{ type: 'text', text: JSON.stringify(response) }],
                };
            } catch (err) {
                return errorEnvelope('flutter_wait_for_request', err);
            }
        },
    );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Build a VM Service extension param object with every value coerced to a
 * string (the contract `developer.registerExtension` exposes to handlers).
 * `undefined` keys are dropped so absent and empty never both reach the
 * Dart side — mirrors the FormRequest `prepared` discipline.
 *
 * Booleans collapse to `"true"` / `"false"` (the standard Dart parser-friendly
 * form). Numbers collapse via `String(n)` which preserves integer fidelity
 * for the int-only fields we forward here.
 */
function stringifyExtParams(
    raw: Record<string, string | number | boolean | undefined>,
): Record<string, string> {
    const out: Record<string, string> = {};
    for (const [key, value] of Object.entries(raw)) {
        if (value === undefined) continue;
        out[key] = typeof value === 'string' ? value : String(value);
    }
    return out;
}

/**
 * Wrap an arbitrary thrown value in an MCP `isError: true` envelope tagged
 * with the originating tool name. The agent sees the message verbatim; the
 * SDK does NOT swallow custom text from explicit envelopes (unlike re-thrown
 * errors, which it converts to a generic envelope).
 */
function errorEnvelope(toolName: string, err: unknown): CallToolResult {
    const message = err instanceof Error ? err.message : String(err);
    return {
        content: [
            {
                type: 'text',
                text: `${toolName}: ${message}`,
            },
        ],
        isError: true,
    };
}
