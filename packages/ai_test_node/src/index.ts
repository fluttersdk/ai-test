#!/usr/bin/env -S npx tsx
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { existsSync, readFileSync } from 'node:fs';
import { VmServiceClient } from './vm_service_client.js';
import { registerAll } from './tools/index.js';

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
    if (fromEnv && fromEnv.length > 0) return fromEnv;
    return DEFAULT_VM_SERVICE_URI;
}

/**
 * Lazy single-flight VM Service connection.
 *
 * The MCP server boots before the Flutter app may be running. Connecting at
 * startup would crash the process; instead, we defer the WebSocket handshake
 * until the first tool call hits `getIsolateId()` or `call()`. Concurrent
 * first calls share a single in-flight connect promise.
 */
function lazyVmClient(uriResolver: () => string): VmServiceClient {
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
            // Reset so a subsequent call retries (operator restarts the app, etc).
            connectPromise = null;
            throw err;
        });
        await connectPromise;
    };

    // Returned proxy delegates to the current client instance via closure so
    // tools always see the live connection even after a URI swap.
    const proxy = {
        get isConnected(): boolean {
            return client.isConnected;
        },
        connect: () => ensureConnected(),
        disconnect: () => client.disconnect(),
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
            return client.call<T>(method, params);
        },
    } as unknown as VmServiceClient;
    return proxy;
}

/**
 * Boot the ai-test MCP server, wire stdio transport, register the three tools,
 * and run until the host disconnects. Errors during the lifetime of a tool
 * call are returned through the MCP error envelope; only fatal transport
 * issues escape this function.
 */
export async function main(): Promise<void> {
    const server = new Server(
        {
            name: 'ai-test-mcp',
            version: '0.1.0',
        },
        {
            capabilities: {
                tools: {},
            },
        },
    );

    const vmClient = lazyVmClient(resolveVmServiceUri);
    registerAll(server, vmClient);

    const transport = new StdioServerTransport();
    await server.connect(transport);
    // server.connect() resolves only when the transport closes; the process
    // then exits naturally. No explicit loop needed.
}

// Direct-invocation guard. Skipped when imported as a module (e.g. by tests).
const invokedDirectly = process.argv[1] !== undefined && import.meta.url === `file://${process.argv[1]}`;
if (invokedDirectly) {
    main().catch((err: unknown) => {
        // eslint-disable-next-line no-console
        console.error('[ai-test-mcp] fatal:', err);
        process.exit(1);
    });
}
