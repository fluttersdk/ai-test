import { existsSync, readFileSync } from 'node:fs';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { VmServiceClient } from './vm_service_client.js';
import { registerNavigationTools } from './tools/navigation.js';
import { registerInteractionTools } from './tools/interaction.js';
import { registerSnapshotTools } from './tools/snapshot.js';
import { registerNetworkTools } from './tools/network.js';

/**
 * Default VM Service WebSocket endpoint exposed by `flutter run` debug
 * sessions on any target (chrome/macos/linux/windows/ios/android). The MCP
 * server is target-agnostic; it just speaks the VM Service Protocol over
 * the WebSocket the CLI scraped into state.json.
 */
const DEFAULT_VM_SERVICE_URI = 'ws://127.0.0.1:8181/ws';

/**
 * Path the V3 CLI (`dart run ai_test_flutter:ai_test_flutter start`) writes
 * the live state file to. Contains JSON with `vmServiceUri` + `pid` + `webPort`
 * + `startedAt`. Flutter web ignores `--vm-service-port` and picks a random
 * port with a per-launch auth token, so the URI cannot be hardcoded.
 * Discovery order: state.json > legacy /tmp file > env > default.
 */
const STATE_JSON_PATH = `${process.env.HOME ?? ''}/.ai-test/state.json`;
const LEGACY_VM_URI_FILE = '/tmp/ai-test-vm-uri';

/**
 * Resolve the VM Service URI. Lazy: re-reads the state file on every call so
 * the URI tracks Flutter app restarts without restarting the MCP server.
 * Falls back to a legacy `/tmp/ai-test-vm-uri` (pre-CLI), then env, then the
 * default endpoint.
 */
function resolveVmServiceUri(): string {
    // 1. V3 path: ~/.ai-test/state.json with {vmServiceUri: ...}.
    try {
        if (existsSync(STATE_JSON_PATH)) {
            const raw = readFileSync(STATE_JSON_PATH, 'utf8');
            const state = JSON.parse(raw) as { vmServiceUri?: string };
            if (typeof state.vmServiceUri === 'string' && state.vmServiceUri.length > 0) {
                return state.vmServiceUri;
            }
        }
    } catch {
        // ignore; fall through to legacy
    }
    // 2. Legacy V2 path retained for backward compatibility.
    try {
        if (existsSync(LEGACY_VM_URI_FILE)) {
            const fromFile = readFileSync(LEGACY_VM_URI_FILE, 'utf8').trim();
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
 * Build a fresh MCP server instance with all 19 V3 tool slots registered via
 * the four Wave 6 tool-group modules. Each module self-registers its tools
 * through `server.registerTool`; this factory only wires them together and
 * exposes the result as a ready-to-connect `McpServer`.
 *
 * The factory takes an optional pre-built `vmClient` for test injection. In
 * production callers (`src/cli.ts`) omit it and the factory wires the lazy
 * connection that reads `/tmp/ai-test-vm-uri` on demand.
 *
 * @param vmClient Optional pre-built lazy VM client (test injection).
 * @returns A configured `McpServer` ready for `.connect(transport)`.
 */
export function createServer(vmClient: LazyVmClient = lazyVmClient()): McpServer {
    const server = new McpServer({
        name: 'ai-test-node',
        version: '3.0.0',
    });

    // 1. Navigation + lifecycle (flutter_navigate, flutter_navigate_back,
    //    flutter_close_app, flutter_resize, flutter_get_routes).
    registerNavigationTools(server, vmClient);

    // 2. Interaction (flutter_tap, flutter_type, flutter_press_key,
    //    flutter_hover, flutter_drag, flutter_select_option, flutter_file_upload).
    registerInteractionTools(server, vmClient);

    // 3. Snapshot + screenshot + evaluate + wait
    //    (flutter_snapshot, flutter_screenshot, flutter_evaluate, flutter_wait_for).
    registerSnapshotTools(server, vmClient);

    // 4. Network + mock (flutter_network_requests, flutter_console_messages,
    //    flutter_mock_http).
    registerNetworkTools(server, vmClient);

    return server;
}
