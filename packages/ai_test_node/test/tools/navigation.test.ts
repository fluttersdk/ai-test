import { describe, expect, it } from 'vitest';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { registerNavigationTools } from '../../src/tools/navigation.js';
import type { LazyVmClient } from '../../src/server.js';

/**
 * Captured call record from the fake `VmServiceClient`. Lets each test assert
 * which `ext.aitest.*` RPC went out and with which params (including the
 * mandatory `isolateId`).
 */
interface CalledMethod {
    readonly method: string;
    readonly params: object | undefined;
}

interface FakeVmClient {
    readonly client: LazyVmClient;
    readonly calls: ReadonlyArray<CalledMethod>;
    readonly disconnectCount: () => number;
}

/**
 * Build a fake `LazyVmClient` that returns a canned response for each method.
 * Records every `call()` and `disconnect()` invocation for later assertion.
 *
 * @param responses Per-method canned values; missing keys cause a thrown error
 *                  (lets tests confirm a tool refuses to fire for an unknown RPC).
 * @param isolateId The fake isolate id returned by `getMainIsolateId`.
 */
function makeFakeVmClient(
    responses: Record<string, unknown>,
    isolateId: string = 'isolates/main-1',
): FakeVmClient {
    const calls: CalledMethod[] = [];
    let disconnects = 0;
    let connected = true;
    const client: LazyVmClient = {
        get isConnected(): boolean {
            return connected;
        },
        connect: async (): Promise<void> => undefined,
        disconnect: async (): Promise<void> => {
            disconnects += 1;
            connected = false;
        },
        getMainIsolateId: async (): Promise<string> => isolateId,
        getRootLibId: async (): Promise<string> => 'rootlib-1',
        clearRootLibCacheForTests: (): void => undefined,
        call: async <T>(method: string, params?: object): Promise<T> => {
            calls.push({ method, params });
            if (!(method in responses)) {
                throw new Error(`fake vmClient: no canned response for ${method}`);
            }
            return responses[method] as T;
        },
    };
    return {
        client,
        calls,
        disconnectCount: (): number => disconnects,
    };
}

/**
 * Spin up an MCP server with ONLY the navigation tools registered, paired with
 * an in-memory Client. Keeps the suite hermetic — no WebSocket, no stdio, no
 * cross-pollination with the 19-slot server catalog under `createServer()`.
 */
async function bootNavigationServer(vmClient: LazyVmClient): Promise<{
    client: Client;
    cleanup: () => Promise<void>;
}> {
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const server = new McpServer({
        name: 'ai-test-navigation-test',
        version: '0.0.0',
    });
    registerNavigationTools(server, vmClient);
    const client = new Client(
        {
            name: 'ai-test-navigation-test-client',
            version: '0.0.0',
        },
        {
            capabilities: {},
        },
    );
    await Promise.all([
        server.connect(serverTransport),
        client.connect(clientTransport),
    ]);
    return {
        client,
        cleanup: async (): Promise<void> => {
            await client.close();
            await server.close();
        },
    };
}

describe('registerNavigationTools()', () => {
    it('registers exactly 5 navigation + lifecycle tools', async () => {
        const fake = makeFakeVmClient({});
        const { client, cleanup } = await bootNavigationServer(fake.client);
        try {
            const { tools } = await client.listTools();
            const names = tools.map((t) => t.name).sort();
            expect(names).toEqual(
                [
                    'flutter_close_app',
                    'flutter_get_routes',
                    'flutter_navigate',
                    'flutter_navigate_back',
                    'flutter_resize',
                ].sort(),
            );
        } finally {
            await cleanup();
        }
    });

    describe('flutter_navigate', () => {
        it('calls ext.aitest.navigate with {isolateId, route} and returns the JSON body as text', async () => {
            const fake = makeFakeVmClient({
                'ext.aitest.navigate': {
                    navigated: true,
                    route: '/dashboard',
                },
            });
            const { client, cleanup } = await bootNavigationServer(fake.client);
            try {
                const result = await client.callTool({
                    name: 'flutter_navigate',
                    arguments: { route: '/dashboard' },
                });
                expect(result.isError).toBeFalsy();
                const content = result.content as ReadonlyArray<{ type: string; text: string }>;
                expect(content[0]?.type).toBe('text');
                expect(JSON.parse(content[0]!.text)).toEqual({
                    navigated: true,
                    route: '/dashboard',
                });
                expect(fake.calls).toEqual([
                    {
                        method: 'ext.aitest.navigate',
                        params: { isolateId: 'isolates/main-1', route: '/dashboard' },
                    },
                ]);
            } finally {
                await cleanup();
            }
        });

        it('rejects missing route via zod (route is required)', async () => {
            const fake = makeFakeVmClient({});
            const { client, cleanup } = await bootNavigationServer(fake.client);
            try {
                // The McpServer surfaces zod parse failures as an isError
                // envelope (not a thrown rejection) so the agent sees the
                // validation message inline rather than as a protocol fault.
                const result = await client.callTool({
                    name: 'flutter_navigate',
                    arguments: {},
                });
                expect(result.isError).toBe(true);
                const content = result.content as ReadonlyArray<{
                    type: string;
                    text: string;
                }>;
                expect(content[0]?.text).toContain('Input validation error');
                expect(fake.calls).toEqual([]);
            } finally {
                await cleanup();
            }
        });

        it('wraps VM Service failures as an isError envelope', async () => {
            const fake: FakeVmClient = {
                ...makeFakeVmClient({}),
            };
            // Override `call` to always reject for this test.
            const erroringClient: LazyVmClient = {
                ...fake.client,
                call: async <T>(): Promise<T> => {
                    throw new Error('VM Service unreachable');
                },
            };
            const { client, cleanup } = await bootNavigationServer(erroringClient);
            try {
                const result = await client.callTool({
                    name: 'flutter_navigate',
                    arguments: { route: '/x' },
                });
                expect(result.isError).toBe(true);
                const content = result.content as ReadonlyArray<{ type: string; text: string }>;
                expect(content[0]?.type).toBe('text');
                expect(content[0]?.text).toContain('VM Service unreachable');
            } finally {
                await cleanup();
            }
        });
    });

    describe('flutter_navigate_back', () => {
        it('calls ext.aitest.navigate_back with {isolateId} only', async () => {
            const fake = makeFakeVmClient({
                'ext.aitest.navigate_back': { navigatedBack: true },
            });
            const { client, cleanup } = await bootNavigationServer(fake.client);
            try {
                const result = await client.callTool({
                    name: 'flutter_navigate_back',
                    arguments: {},
                });
                expect(result.isError).toBeFalsy();
                const content = result.content as ReadonlyArray<{ type: string; text: string }>;
                expect(JSON.parse(content[0]!.text)).toEqual({ navigatedBack: true });
                expect(fake.calls).toEqual([
                    {
                        method: 'ext.aitest.navigate_back',
                        params: { isolateId: 'isolates/main-1' },
                    },
                ]);
            } finally {
                await cleanup();
            }
        });
    });

    describe('flutter_get_routes', () => {
        it('calls ext.aitest.get_routes with {isolateId} only', async () => {
            const fake = makeFakeVmClient({
                'ext.aitest.get_routes': {
                    location: '/monitors',
                    title: 'Monitors',
                },
            });
            const { client, cleanup } = await bootNavigationServer(fake.client);
            try {
                const result = await client.callTool({
                    name: 'flutter_get_routes',
                    arguments: {},
                });
                expect(result.isError).toBeFalsy();
                const content = result.content as ReadonlyArray<{ type: string; text: string }>;
                expect(JSON.parse(content[0]!.text)).toEqual({
                    location: '/monitors',
                    title: 'Monitors',
                });
                expect(fake.calls).toEqual([
                    {
                        method: 'ext.aitest.get_routes',
                        params: { isolateId: 'isolates/main-1' },
                    },
                ]);
            } finally {
                await cleanup();
            }
        });
    });

    describe('flutter_close_app', () => {
        it('soft-closes by calling vmClient.disconnect() and returns {closed: true}', async () => {
            const fake = makeFakeVmClient({});
            const { client, cleanup } = await bootNavigationServer(fake.client);
            try {
                const result = await client.callTool({
                    name: 'flutter_close_app',
                    arguments: {},
                });
                expect(result.isError).toBeFalsy();
                const content = result.content as ReadonlyArray<{ type: string; text: string }>;
                expect(JSON.parse(content[0]!.text)).toEqual({ closed: true });
                // No ext.aitest.* call goes out — soft-close is a client-side
                // disconnect only (no matching Dart-side extension exists).
                expect(fake.calls).toEqual([]);
                expect(fake.disconnectCount()).toBe(1);
            } finally {
                await cleanup();
            }
        });
    });

    describe('flutter_resize', () => {
        it('returns an isError envelope explaining the ALPHA-phase gap', async () => {
            const fake = makeFakeVmClient({});
            const { client, cleanup } = await bootNavigationServer(fake.client);
            try {
                const result = await client.callTool({
                    name: 'flutter_resize',
                    arguments: { width: 1440, height: 900 },
                });
                expect(result.isError).toBe(true);
                const content = result.content as ReadonlyArray<{ type: string; text: string }>;
                expect(content[0]?.type).toBe('text');
                expect(content[0]?.text).toContain('flutter_resize not yet implemented');
                expect(fake.calls).toEqual([]);
            } finally {
                await cleanup();
            }
        });

        it('still validates {width, height} as numbers before short-circuiting', async () => {
            const fake = makeFakeVmClient({});
            const { client, cleanup } = await bootNavigationServer(fake.client);
            try {
                // McpServer parses zod inputs BEFORE dispatching the handler;
                // a string width must surface as an isError envelope (not as
                // the ALPHA-phase "not yet implemented" message).
                const result = await client.callTool({
                    name: 'flutter_resize',
                    arguments: { width: 'wide', height: 900 },
                });
                expect(result.isError).toBe(true);
                const content = result.content as ReadonlyArray<{
                    type: string;
                    text: string;
                }>;
                expect(content[0]?.text).toContain('Input validation error');
                expect(content[0]?.text).not.toContain('not yet implemented');
            } finally {
                await cleanup();
            }
        });
    });
});
