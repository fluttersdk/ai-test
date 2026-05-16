import { existsSync, readFileSync } from 'node:fs';
import { z } from 'zod';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { VmServiceClient } from './vm_service_client.js';

/**
 * Default VM Service WebSocket endpoint exposed by
 * `flutter run -d chrome --enable-vm-service --disable-service-auth-codes`.
 */
const DEFAULT_VM_SERVICE_URI = 'ws://127.0.0.1:8181/ws';

/**
 * Path the launch script (`scripts/dev-with-aitest.sh`) writes the live VM
 * Service URI to. Flutter web ignores `--vm-service-port` + `--disable-service-
 * auth-codes` and picks a random port with a per-launch auth token, so the URI
 * cannot be hardcoded. Discovery order: file > env > default.
 */
const VM_URI_FILE = '/tmp/ai-test-vm-uri';

/**
 * Resolve the VM Service URI. Lazy: re-reads the discovery file on every call
 * so the URI tracks Flutter app restarts without restarting the MCP server.
 * Falls back to env, then the default endpoint.
 */
function resolveVmServiceUri(): string {
    try {
        if (existsSync(VM_URI_FILE)) {
            const fromFile = readFileSync(VM_URI_FILE, 'utf8').trim();
            if (fromFile.length > 0) return fromFile;
        }
    } catch {
        // ignore; fall through to env
    }
    const fromEnv = process.env.AI_TEST_VM_SERVICE_URI;
    if (fromEnv !== undefined && fromEnv.length > 0) return fromEnv;
    return DEFAULT_VM_SERVICE_URI;
}

/**
 * Public proxy interface for the lazy VM Service connection. Mirrors the
 * `VmServiceClient` surface the Wave 6 tool wrappers consume — the proxy
 * connects on the first delegated call and re-connects transparently when
 * the discovery file points at a new URI.
 */
export interface LazyVmClient {
    readonly isConnected: boolean;
    connect(): Promise<void>;
    disconnect(): Promise<void>;
    getMainIsolateId(): Promise<string>;
    getRootLibId(isolateId: string): Promise<string>;
    clearRootLibCacheForTests(): void;
    call<T>(method: string, params?: object): Promise<T>;
}

/**
 * Lazy single-flight VM Service connection.
 *
 * The MCP server boots before the Flutter app may be running. Connecting at
 * startup would crash the process; instead, we defer the WebSocket handshake
 * until the first tool call hits `getMainIsolateId()` or `call()`. Concurrent
 * first calls share a single in-flight connect promise.
 */
export function lazyVmClient(uriResolver: () => string = resolveVmServiceUri): LazyVmClient {
    // Resolve once for the first connect; if the URI changes later (Flutter
    // restart writes a new value to VM_URI_FILE), the connection fails on the
    // next call and we recreate the underlying client transparently.
    let currentUri = uriResolver();
    let client = new VmServiceClient(currentUri);
    let connectPromise: Promise<void> | null = null;

    const ensureConnected = async (): Promise<void> => {
        const latestUri = uriResolver();
        if (latestUri !== currentUri) {
            // URI changed (Flutter app restarted). Tear down + recreate.
            await client.disconnect().catch(() => undefined);
            currentUri = latestUri;
            client = new VmServiceClient(currentUri);
            connectPromise = null;
        }
        if (client.isConnected) return;
        connectPromise ??= client.connect().catch((err: Error) => {
            // Reset so a subsequent call retries (operator restarts the app).
            connectPromise = null;
            throw err;
        });
        await connectPromise;
    };

    return {
        get isConnected(): boolean {
            return client.isConnected;
        },
        connect: (): Promise<void> => ensureConnected(),
        disconnect: (): Promise<void> => client.disconnect(),
        getMainIsolateId: async (): Promise<string> => {
            await ensureConnected();
            return client.getMainIsolateId();
        },
        getRootLibId: async (isolateId: string): Promise<string> => {
            await ensureConnected();
            return client.getRootLibId(isolateId);
        },
        clearRootLibCacheForTests: (): void => client.clearRootLibCacheForTests(),
        call: async <T>(method: string, params?: object): Promise<T> => {
            await ensureConnected();
            return client.call<T>(method, params ?? {});
        },
    };
}

/**
 * Uniform "NOT YET IMPLEMENTED" envelope returned by every stub tool registered
 * in Step 18. Wave 6 (Steps 19-22) replaces each `registerStub` call site with
 * the real handler. The `isError: true` flag follows the MCP convention for
 * tool-level errors: clients see the failure without the JSON-RPC layer
 * raising a protocol-level exception.
 */
function notYetImplemented(): CallToolResult {
    return {
        content: [
            {
                type: 'text',
                text: 'NOT YET IMPLEMENTED',
            },
        ],
        isError: true,
    };
}

/**
 * Schema-and-description pair backing a single tool slot. Keeping the table
 * of 19 entries co-located here makes the V3 catalog auditable at a glance and
 * keeps the empty handlers terse — `createServer()` iterates the table and
 * registers each slot via `McpServer.registerTool`.
 */
interface StubToolSpec {
    readonly name: string;
    readonly description: string;
    /**
     * Zod raw shape (object property → ZodType). Empty object `{}` for the
     * zero-arg tools (e.g. `flutter_navigate_back`, `flutter_snapshot`). The
     * SDK widens `{}` into a no-arg `inputSchema`.
     */
    readonly inputSchema: z.ZodRawShape;
}

/**
 * V3 MCP tool catalog (19 entries).
 *
 * Post-Oracle-cull names ONLY. The four dropped tools (`flutter_inspect_state`,
 * `flutter_inspect_form`, `flutter_handle_dialog`, `flutter_hot_reload`) must
 * never appear here — re-introducing any of them violates the V3 contract and
 * breaks the `flutter test` aggregator in Step 22b.
 *
 * Schemas are intentionally permissive at the stub stage: they capture the
 * argument NAMES the Wave 6 wrappers will validate strictly, but use `optional`
 * everywhere so the Step 18 smoke test (`tools/call` with empty args) does not
 * fail at zod parsing before hitting the stub handler.
 */
const STUB_TOOLS: ReadonlyArray<StubToolSpec> = [
    // 1. V2 carry-overs (renamed per V3 naming convention).
    {
        name: 'flutter_evaluate',
        description:
            'Run a Dart expression inside the running app (scoped to the root library). Use for state inspection beyond the widget tree, e.g. `Magic.find<MonitorController>().rxState.value` or `Auth.user()?.email`.',
        inputSchema: {
            expression: z.string().optional(),
        },
    },
    {
        name: 'flutter_get_routes',
        description:
            'Return the current GoRouter location and page title. Use after navigation to verify the route changed.',
        inputSchema: {},
    },

    // 2. Navigation + lifecycle (Wave 6 Step 19).
    {
        name: 'flutter_navigate',
        description:
            'Push a named or path route on the running app. Equivalent to `MagicRoute.to(<path>)` on the Dart side.',
        inputSchema: {
            location: z.string().optional(),
        },
    },
    {
        name: 'flutter_navigate_back',
        description:
            'Pop the topmost route. Equivalent to `MagicRoute.back()` on the Dart side.',
        inputSchema: {},
    },
    {
        name: 'flutter_close_app',
        description:
            'Tear down the running Flutter app cleanly. Useful between scenarios to reset all in-memory state.',
        inputSchema: {},
    },
    {
        name: 'flutter_resize',
        description:
            'Resize the Flutter viewport. Width and height in logical pixels; honours `MediaQuery` listeners and triggers a relayout.',
        inputSchema: {
            width: z.number().optional(),
            height: z.number().optional(),
        },
    },

    // 3. Interaction (Wave 6 Step 20).
    {
        name: 'flutter_tap',
        description:
            'Tap (single click) on the widget referenced by `ref`. The `ref` comes from a prior `flutter_snapshot` call.',
        inputSchema: {
            ref: z.string().optional(),
        },
    },
    {
        name: 'flutter_type',
        description:
            'Type text into the field referenced by `ref`. Replaces any existing text in the field.',
        inputSchema: {
            ref: z.string().optional(),
            text: z.string().optional(),
        },
    },
    {
        name: 'flutter_press_key',
        description:
            'Press a single keyboard key (e.g. "Enter", "Escape", "Tab", "ArrowDown"). Targets the currently focused widget.',
        inputSchema: {
            key: z.string().optional(),
        },
    },
    {
        name: 'flutter_hover',
        description:
            'Hover the pointer over the widget referenced by `ref`. Use to trigger hover-only UI such as tooltips.',
        inputSchema: {
            ref: z.string().optional(),
        },
    },
    {
        name: 'flutter_drag',
        description:
            'Drag from the widget at `startRef` to the widget at `endRef`. Used for re-orderable lists and slider widgets.',
        inputSchema: {
            startRef: z.string().optional(),
            endRef: z.string().optional(),
        },
    },
    {
        name: 'flutter_select_option',
        description:
            'Select one or more options in the dropdown referenced by `ref`. `values` is the list of option labels (or values) to select.',
        inputSchema: {
            ref: z.string().optional(),
            values: z.array(z.string()).optional(),
        },
    },
    {
        name: 'flutter_file_upload',
        description:
            'Attach files to a file-input referenced by `ref`. Note: browser-side file pickers cannot be filled from the agent; the wrapper returns a `{uploaded: false, reason: ...}` envelope so the agent can detect the limitation instead of silently failing.',
        inputSchema: {
            ref: z.string().optional(),
            paths: z.array(z.string()).optional(),
        },
    },

    // 4. Snapshot + screenshot + wait (Wave 6 Step 21).
    {
        name: 'flutter_snapshot',
        description:
            'Capture a structured YAML snapshot of the current widget tree. Returned `ref` tokens feed every interaction tool (`flutter_tap`, `flutter_type`, ...).',
        inputSchema: {},
    },
    {
        name: 'flutter_screenshot',
        description:
            'Capture a PNG (default) or JPEG of the running app viewport. Returned as base64 image content; agents can compare against fixtures or feed to multimodal reasoning.',
        inputSchema: {
            format: z.enum(['png', 'jpeg']).optional(),
            quality: z.number().optional(),
        },
    },
    {
        name: 'flutter_wait_for',
        description:
            'Wait until a predicate evaluates truthy (Dart expression in the root library scope) or the timeout elapses. Polls every 100ms.',
        inputSchema: {
            condition: z.string().optional(),
            timeoutMs: z.number().optional(),
        },
    },

    // 5. Network + mock (Wave 6 Step 22).
    {
        name: 'flutter_network_requests',
        description:
            'Return the list of HTTP requests the app has issued since the last `flutter_snapshot` (or since boot, if no snapshot was taken).',
        inputSchema: {},
    },
    {
        name: 'flutter_console_messages',
        description:
            'Return the list of console log entries (info / warning / error / debug) the app has emitted since the last `flutter_snapshot`.',
        inputSchema: {},
    },
    {
        name: 'flutter_mock_http',
        description:
            'Install an HTTP mock for the given URL pattern. Subsequent `Http` facade calls matching the pattern return the canned response instead of hitting the network.',
        inputSchema: {
            pattern: z.string().optional(),
            response: z.unknown().optional(),
        },
    },
];

/**
 * Build a fresh MCP server instance with all 19 V3 tool slots registered as
 * NOT-YET-IMPLEMENTED stubs. Wave 6 will replace these registrations with the
 * real handlers (Steps 19-22) and Step 22b will wire a single aggregator.
 *
 * The factory takes an optional pre-built `vmClient` for test injection. In
 * production callers (`src/cli.ts`) omit it and the factory wires the lazy
 * connection that reads `/tmp/ai-test-vm-uri` on demand.
 *
 * @param vmClient Optional pre-built lazy VM client (test injection).
 * @returns A configured `McpServer` ready for `.connect(transport)`.
 */
export function createServer(vmClient: LazyVmClient = lazyVmClient()): McpServer {
    // `vmClient` is held under closure so Wave 6 tool wrappers can capture it
    // when they replace the stub handlers; for Step 18 we reference it only via
    // the underscore alias to silence the unused-binding diagnostic.
    void vmClient;

    const server = new McpServer({
        name: 'ai-test-node',
        version: '3.0.0',
    });

    for (const spec of STUB_TOOLS) {
        server.registerTool(
            spec.name,
            {
                description: spec.description,
                inputSchema: spec.inputSchema,
            },
            (): CallToolResult => notYetImplemented(),
        );
    }

    return server;
}
