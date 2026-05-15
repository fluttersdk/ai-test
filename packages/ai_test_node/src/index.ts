#!/usr/bin/env -S npx tsx
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { VmServiceClient } from './vm_service_client.js';
import { registerAll } from './tools/index.js';

/**
 * Default VM Service WebSocket endpoint exposed by
 * `flutter run -d chrome --enable-vm-service --disable-service-auth-codes`.
 */
const DEFAULT_VM_SERVICE_URI = 'ws://127.0.0.1:8181/ws';

/**
 * Resolve the VM Service URI from `AI_TEST_VM_SERVICE_URI` or fall back to the
 * default debug endpoint. Hardcoding is forbidden; operators running with
 * `--service-port` or auth-codes-on supply the URI via env.
 */
function resolveVmServiceUri(): string {
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
function lazyVmClient(uri: string): VmServiceClient {
    const client = new VmServiceClient(uri);
    let connectPromise: Promise<void> | null = null;

    const ensureConnected = async (): Promise<void> => {
        if (client.isConnected) return;
        connectPromise ??= client.connect().catch((err: Error) => {
            // Reset so a subsequent call retries (operator restarts the app, etc).
            connectPromise = null;
            throw err;
        });
        await connectPromise;
    };

    const originalCall = client.call.bind(client);
    const originalGetMainIsolateId = client.getMainIsolateId.bind(client);

    client.call = async (method, params) => {
        await ensureConnected();
        return originalCall(method, params);
    };
    client.getMainIsolateId = async () => {
        await ensureConnected();
        return originalGetMainIsolateId();
    };

    return client;
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

    const vmClient = lazyVmClient(resolveVmServiceUri());
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
