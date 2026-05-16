import { z } from 'zod';
import type { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { VmServiceError } from '../vm_service_client.js';
import type { LazyVmClient } from '../server.js';
import { makeToolContext, type ToolContext } from './index.js';

/**
 * MCP tool wrappers for the V3 interaction surface (Wave 6 Step 20).
 *
 * Mirrors Playwright-MCP's interaction tools onto the seven Dart-side
 * `ext.aitest.*` extensions registered by `ai_test_flutter`'s
 * `ext_pointer.dart`, `ext_text_input.dart`, and `ext_scroll.dart`. Each tool
 * accepts a `ref` (and tool-specific extra fields) and forwards the payload to
 * the matching VM Service extension with `isolateId` injected.
 *
 * `flutter_file_upload` is the lone exception: browser File API inputs cannot
 * be programmatically filled from the VM Service, so the tool returns a
 * `{ isError: true }` envelope without contacting the running app. The slot
 * exists so an LLM agent discovers the limitation explicitly instead of
 * guessing why a `flutter_tap` on the file picker did nothing. Real upload
 * support lands in V3.1 via an HTTP API workaround.
 *
 * Self-registration: `registerInteractionTools(server, vmClient)` is invoked
 * by the Step 22b aggregator after the McpServer instance is created. No
 * edit to `src/server.ts` is required from this step.
 */

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/**
 * Wrap a Dart-side response object as an MCP text-content tool result.
 *
 * The MCP spec has no `json` content variant; structured payloads ship as
 * JSON-stringified text. Agents re-parse on their side.
 */
function asTextResult(payload: unknown): CallToolResult {
    return {
        content: [{ type: 'text', text: JSON.stringify(payload) }],
    };
}

/**
 * Wrap an error message as an MCP `{ isError: true }` envelope.
 *
 * Per V3 plan Stage 3 D7 and the MCP convention: tool-level failures are
 * reported through `isError: true` rather than JSON-RPC protocol exceptions
 * so the agent can read the failure text without the client dropping the
 * response.
 */
function asErrorResult(message: string): CallToolResult {
    return {
        content: [{ type: 'text', text: message }],
        isError: true,
    };
}

/**
 * Translate a thrown exception into an MCP error envelope. `VmServiceError`s
 * surface their message verbatim; unknown throws fall back to `String(err)`.
 */
function errorEnvelopeFor(toolName: string, err: unknown): CallToolResult {
    if (err instanceof VmServiceError) {
        return asErrorResult(`${toolName}: ${err.message}`);
    }
    if (err instanceof Error) {
        return asErrorResult(`${toolName}: ${err.message}`);
    }
    return asErrorResult(`${toolName}: ${String(err)}`);
}

// ---------------------------------------------------------------------------
// Per-tool registrations
// ---------------------------------------------------------------------------

/**
 * Register the 7 interaction tools on `server`, using `vmClient` for VM
 * Service calls. Internal `ToolContext` caches the main isolate id under
 * closure so the lookup runs at most once per server lifetime.
 *
 * The 7 tools:
 * - `flutter_tap` — single tap at a ref.
 * - `flutter_type` — replace text inside the field at a ref.
 * - `flutter_press_key` — physical key press, optionally with modifiers.
 * - `flutter_hover` — mouse-kind hover over a ref.
 * - `flutter_drag` — pointer drag from startRef to endRef.
 * - `flutter_select_option` — select a value on the dropdown at a ref.
 * - `flutter_scroll` — scroll into view OR by dy on a Scrollable.
 * - `flutter_file_upload` — DEFERRED to V3.1 (slot returns `isError: true`).
 */
export function registerInteractionTools(
    server: McpServer,
    vmClient: LazyVmClient,
): void {
    const ctx: ToolContext = makeToolContext(vmClient);

    registerFlutterTap(server, ctx);
    registerFlutterType(server, ctx);
    registerFlutterPressKey(server, ctx);
    registerFlutterHover(server, ctx);
    registerFlutterDrag(server, ctx);
    registerFlutterSelectOption(server, ctx);
    registerFlutterScroll(server, ctx);
    registerFlutterFileUpload(server);
}

// ---------------------------------------------------------------------------
// flutter_tap
// ---------------------------------------------------------------------------

const TAP_INPUT_SCHEMA = {
    ref: z
        .string()
        .min(1, 'ref must be a non-empty snapshot reference string')
        .describe(
            'Opaque ref string (eN) returned by a prior `flutter_snapshot` call.',
        ),
} as const;

function registerFlutterTap(server: McpServer, ctx: ToolContext): void {
    server.registerTool(
        'flutter_tap',
        {
            description:
                'Tap (single click) the widget referenced by `ref`. The ref comes from a prior `flutter_snapshot` call. Triggers `GestureDetector.onTap` and grants keyboard focus when the target is a text field.',
            inputSchema: TAP_INPUT_SCHEMA,
        },
        async (args): Promise<CallToolResult> => {
            try {
                const isolateId = await ctx.getIsolateId();
                const result = await ctx.call<unknown>('ext.aitest.tap', {
                    isolateId,
                    ref: args.ref,
                });
                return asTextResult(result);
            } catch (err) {
                return errorEnvelopeFor('flutter_tap', err);
            }
        },
    );
}

// ---------------------------------------------------------------------------
// flutter_type
// ---------------------------------------------------------------------------

const TYPE_INPUT_SCHEMA = {
    ref: z
        .string()
        .min(1, 'ref must be a non-empty snapshot reference string')
        .describe('Snapshot ref for the target text field.'),
    text: z
        .string()
        .describe(
            'Text to type into the field. Replaces any existing content; pass an empty string to clear the field.',
        ),
} as const;

function registerFlutterType(server: McpServer, ctx: ToolContext): void {
    server.registerTool(
        'flutter_type',
        {
            description:
                'Type text into the field referenced by `ref`. Replaces any existing text in the field. Sets the `TextEditingController.value` directly and requests keyboard focus so IME state stays coherent.',
            inputSchema: TYPE_INPUT_SCHEMA,
        },
        async (args): Promise<CallToolResult> => {
            try {
                const isolateId = await ctx.getIsolateId();
                const result = await ctx.call<unknown>('ext.aitest.type', {
                    isolateId,
                    ref: args.ref,
                    text: args.text,
                });
                return asTextResult(result);
            } catch (err) {
                return errorEnvelopeFor('flutter_type', err);
            }
        },
    );
}

// ---------------------------------------------------------------------------
// flutter_press_key
// ---------------------------------------------------------------------------

const PRESS_KEY_INPUT_SCHEMA = {
    key: z
        .string()
        .min(1, 'key must be a non-empty key name')
        .describe(
            'Key name string. Supported values: Enter, Tab, Escape, Backspace, Delete, Space, ArrowUp/Down/Left/Right, Home, End, PageUp, PageDown, F1-F12.',
        ),
    modifiers: z
        .array(z.string())
        .optional()
        .describe(
            'Optional modifier key names (e.g. ["Control", "Shift"]). Accepted but not yet wired to synthesized modifier events on the Dart side.',
        ),
} as const;

function registerFlutterPressKey(server: McpServer, ctx: ToolContext): void {
    server.registerTool(
        'flutter_press_key',
        {
            description:
                'Press a single keyboard key (e.g. "Enter", "Escape", "Tab", "ArrowDown") via `HardwareKeyboard.handleKeyEvent`. Targets the currently focused widget. Modifiers are accepted but reserved for V3.1.',
            inputSchema: PRESS_KEY_INPUT_SCHEMA,
        },
        async (args): Promise<CallToolResult> => {
            try {
                const isolateId = await ctx.getIsolateId();
                // The Dart handler reads `Map<String, String>`; collapse the
                // modifiers array to a comma-joined string the handler splits
                // back into the modifier list. Omit the param entirely when
                // empty so the Dart side falls through to the default.
                const params: Record<string, string> = {
                    isolateId,
                    key: args.key,
                };
                if (args.modifiers && args.modifiers.length > 0) {
                    params['modifiers'] = args.modifiers.join(',');
                }
                const result = await ctx.call<unknown>(
                    'ext.aitest.press_key',
                    params,
                );
                return asTextResult(result);
            } catch (err) {
                return errorEnvelopeFor('flutter_press_key', err);
            }
        },
    );
}

// ---------------------------------------------------------------------------
// flutter_hover
// ---------------------------------------------------------------------------

const HOVER_INPUT_SCHEMA = {
    ref: z
        .string()
        .min(1, 'ref must be a non-empty snapshot reference string')
        .describe('Snapshot ref for the widget to hover over.'),
} as const;

function registerFlutterHover(server: McpServer, ctx: ToolContext): void {
    server.registerTool(
        'flutter_hover',
        {
            description:
                'Hover the pointer over the widget referenced by `ref`. Emits a `PointerHoverEvent` with mouse kind so `MouseRegion.onEnter` callbacks (tooltips, hover-only UI) fire.',
            inputSchema: HOVER_INPUT_SCHEMA,
        },
        async (args): Promise<CallToolResult> => {
            try {
                const isolateId = await ctx.getIsolateId();
                const result = await ctx.call<unknown>('ext.aitest.hover', {
                    isolateId,
                    ref: args.ref,
                });
                return asTextResult(result);
            } catch (err) {
                return errorEnvelopeFor('flutter_hover', err);
            }
        },
    );
}

// ---------------------------------------------------------------------------
// flutter_drag
// ---------------------------------------------------------------------------

const DRAG_INPUT_SCHEMA = {
    startRef: z
        .string()
        .min(1, 'startRef must be a non-empty snapshot reference string')
        .describe('Snapshot ref for the drag source widget.'),
    endRef: z
        .string()
        .min(1, 'endRef must be a non-empty snapshot reference string')
        .describe('Snapshot ref for the drag destination widget.'),
} as const;

function registerFlutterDrag(server: McpServer, ctx: ToolContext): void {
    server.registerTool(
        'flutter_drag',
        {
            description:
                'Drag from the widget at `startRef` to the widget at `endRef`. Emits a Down + 5×Move + Up pointer sequence so velocity recognizers compute a valid drag velocity. Used for re-orderable lists and slider widgets.',
            inputSchema: DRAG_INPUT_SCHEMA,
        },
        async (args): Promise<CallToolResult> => {
            try {
                const isolateId = await ctx.getIsolateId();
                const result = await ctx.call<unknown>('ext.aitest.drag', {
                    isolateId,
                    startRef: args.startRef,
                    endRef: args.endRef,
                });
                return asTextResult(result);
            } catch (err) {
                return errorEnvelopeFor('flutter_drag', err);
            }
        },
    );
}

// ---------------------------------------------------------------------------
// flutter_select_option
// ---------------------------------------------------------------------------

const SELECT_OPTION_INPUT_SCHEMA = {
    ref: z
        .string()
        .min(1, 'ref must be a non-empty snapshot reference string')
        .describe('Snapshot ref for the dropdown / select widget.'),
    value: z
        .string()
        .describe('Option value (or label) to select on the target dropdown.'),
} as const;

function registerFlutterSelectOption(
    server: McpServer,
    ctx: ToolContext,
): void {
    server.registerTool(
        'flutter_select_option',
        {
            description:
                'Select an option on the dropdown referenced by `ref`. Invokes the widget\'s `onChanged(value)` callback directly without going through a hit-test, which is the only safe path for `DropdownButton`-style widgets.',
            inputSchema: SELECT_OPTION_INPUT_SCHEMA,
        },
        async (args): Promise<CallToolResult> => {
            try {
                const isolateId = await ctx.getIsolateId();
                const result = await ctx.call<unknown>(
                    'ext.aitest.select_option',
                    {
                        isolateId,
                        ref: args.ref,
                        value: args.value,
                    },
                );
                return asTextResult(result);
            } catch (err) {
                return errorEnvelopeFor('flutter_select_option', err);
            }
        },
    );
}

// ---------------------------------------------------------------------------
// flutter_scroll
// ---------------------------------------------------------------------------

const SCROLL_INPUT_SCHEMA = {
    ref: z
        .string()
        .min(1, 'ref must be a non-empty snapshot reference string')
        .optional()
        .describe(
            'Snapshot ref for a widget inside (or that owns) the target Scrollable. ' +
                'Required when `intoView: true`; for delta scrolls falls back to the ' +
                'app-root Scrollable when omitted.',
        ),
    dy: z
        .coerce.number()
        .optional()
        .describe(
            'Vertical scroll delta in logical pixels. Positive scrolls down; ' +
                'negative scrolls up. Ignored when `intoView: true`.',
        ),
    dx: z
        .coerce.number()
        .optional()
        .describe(
            'Horizontal scroll delta in logical pixels. Reserved for future use ' +
                '(no Dart-side support yet); ignored when `intoView: true`.',
        ),
    intoView: z
        .boolean()
        .optional()
        .describe(
            'When true, calls `Scrollable.ensureVisible(element, alignment: 0.5)` ' +
                'so the ref widget scrolls into the viewport center. Required when ' +
                'a delta would not deterministically reveal the target (e.g. sticky ' +
                'bars off the bottom of the page).',
        ),
} as const;

function registerFlutterScroll(server: McpServer, ctx: ToolContext): void {
    server.registerTool(
        'flutter_scroll',
        {
            description:
                'Scroll the widget tree. Pass `{ref, intoView: true}` to scroll the ' +
                'ref into the viewport centre, or `{ref?, dy}` to shift the (root or ' +
                'ref-owning) Scrollable by `dy` logical pixels. Returns the ' +
                "scrollable's final pixel offset.",
            inputSchema: SCROLL_INPUT_SCHEMA,
        },
        async (args): Promise<CallToolResult> => {
            try {
                const isolateId = await ctx.getIsolateId();
                // VM Service extension params are Map<String, String>; coerce
                // booleans + numbers to string before forwarding so the Dart-side
                // handler can `int.tryParse` / `== 'true'` them deterministically.
                const params: Record<string, string> = { isolateId };
                if (args.ref !== undefined) params.ref = args.ref;
                if (args.dy !== undefined) params.dy = String(args.dy);
                if (args.dx !== undefined) params.dx = String(args.dx);
                if (args.intoView !== undefined)
                    params.intoView = args.intoView ? 'true' : 'false';
                const result = await ctx.call<unknown>(
                    'ext.aitest.scroll',
                    params,
                );
                return asTextResult(result);
            } catch (err) {
                return errorEnvelopeFor('flutter_scroll', err);
            }
        },
    );
}

// ---------------------------------------------------------------------------
// flutter_file_upload — DEFERRED to V3.1
// ---------------------------------------------------------------------------

const FILE_UPLOAD_INPUT_SCHEMA = {
    ref: z
        .string()
        .optional()
        .describe(
            'Snapshot ref for the file input widget. Accepted but unused: the tool is deferred to V3.1.',
        ),
    path: z
        .string()
        .optional()
        .describe(
            'Absolute path of the file to upload. Accepted but unused: the tool is deferred to V3.1.',
        ),
} as const;

/**
 * Deferred-to-V3.1 message returned by `flutter_file_upload`. The agent reads
 * this envelope, learns the limitation explicitly, and routes the upload
 * through the HTTP API workaround documented in the V3 README.
 */
const FILE_UPLOAD_DEFERRED_MESSAGE =
    'flutter_file_upload deferred to V3.1 — browser File API cannot be programmatically filled from VM Service. Use HTTP API workaround.';

function registerFlutterFileUpload(server: McpServer): void {
    server.registerTool(
        'flutter_file_upload',
        {
            description:
                'Upload a file to the input referenced by `ref`. DEFERRED to V3.1: the browser File API cannot be programmatically filled from the VM Service, so the wrapper returns an `isError: true` envelope explaining the limitation. The slot is published so an agent discovers the constraint explicitly.',
            inputSchema: FILE_UPLOAD_INPUT_SCHEMA,
        },
        (): CallToolResult => asErrorResult(FILE_UPLOAD_DEFERRED_MESSAGE),
    );
}
