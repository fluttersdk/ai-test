import { describe, expect, it } from 'vitest';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { registerNetworkTools } from '../../src/tools/network.js';
import type { LazyVmClient } from '../../src/server.js';

/**
 * Captured `vmClient.call()` invocation. The network/mock tool group never
 * touches `disconnect()`, so the fake omits that bookkeeping (compare
 * `navigation.test.ts`, which tracks disconnects for `flutter_close_app`).
 */
interface CalledMethod {
    readonly method: string;
    readonly params: object | undefined;
}

interface FakeVmClient {
    readonly client: LazyVmClient;
    readonly calls: ReadonlyArray<CalledMethod>;
}

/**
 * Build a fake `LazyVmClient` that returns a canned response for each method.
 * Records every `call()` invocation for later assertion. Missing keys throw so
 * tests can confirm a tool refuses to fire for an unexpected RPC.
 *
 * @param responses Per-method canned values keyed by full RPC method name.
 * @param isolateId Fake isolate id returned by `getMainIsolateId`.
 */
function makeFakeVmClient(
    responses: Record<string, unknown>,
    isolateId: string = 'isolates/main-1',
): FakeVmClient {
    const calls: CalledMethod[] = [];
    const client: LazyVmClient = {
        get isConnected(): boolean {
            return true;
        },
        connect: async (): Promise<void> => undefined,
        disconnect: async (): Promise<void> => undefined,
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
    return { client, calls };
}

/**
 * Spin up an MCP server with ONLY the network tool group registered, paired
 * with an in-memory Client. Mirrors `navigation.test.ts#bootNavigationServer`.
 */
async function bootNetworkServer(vmClient: LazyVmClient): Promise<{
    client: Client;
    cleanup: () => Promise<void>;
}> {
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const server = new McpServer({
        name: 'ai-test-network-test',
        version: '0.0.0',
    });
    registerNetworkTools(server, vmClient);
    const client = new Client(
        {
            name: 'ai-test-network-test-client',
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

describe('registerNetworkTools()', () => {
    it('registers exactly 3 network + mock tools', async () => {
        const fake = makeFakeVmClient({});
        const { client, cleanup } = await bootNetworkServer(fake.client);
        try {
            const { tools } = await client.listTools();
            const names = tools.map((t) => t.name).sort();
            expect(names).toEqual(
                [
                    'flutter_console_messages',
                    'flutter_mock_http',
                    'flutter_network_requests',
                ].sort(),
            );
        } finally {
            await cleanup();
        }
    });

    // -----------------------------------------------------------------------
    // flutter_network_requests
    // -----------------------------------------------------------------------

    describe('flutter_network_requests', () => {
        it('calls ext.aitest.network_requests with {isolateId} only when no args supplied', async () => {
            const fake = makeFakeVmClient({
                'ext.aitest.network_requests': {
                    requests: [
                        {
                            url: 'https://api.example.com/monitors',
                            method: 'GET',
                            statusCode: 200,
                        },
                    ],
                },
            });
            const { client, cleanup } = await bootNetworkServer(fake.client);
            try {
                const result = await client.callTool({
                    name: 'flutter_network_requests',
                    arguments: {},
                });
                expect(result.isError).toBeFalsy();
                const content = result.content as ReadonlyArray<{ type: string; text: string }>;
                expect(content[0]?.type).toBe('text');
                expect(JSON.parse(content[0]!.text)).toEqual({
                    requests: [
                        {
                            url: 'https://api.example.com/monitors',
                            method: 'GET',
                            statusCode: 200,
                        },
                    ],
                });
                expect(fake.calls).toEqual([
                    {
                        method: 'ext.aitest.network_requests',
                        params: { isolateId: 'isolates/main-1' },
                    },
                ]);
            } finally {
                await cleanup();
            }
        });

        it('forwards optional limit (as string) and filter to the extension', async () => {
            const fake = makeFakeVmClient({
                'ext.aitest.network_requests': { requests: [] },
            });
            const { client, cleanup } = await bootNetworkServer(fake.client);
            try {
                const result = await client.callTool({
                    name: 'flutter_network_requests',
                    arguments: { limit: 25, filter: '/monitors' },
                });
                expect(result.isError).toBeFalsy();
                // VM Service ServiceExtension handlers receive every param as a
                // string. The wrapper stringifies numbers before sending so the
                // Dart-side int.tryParse() receives the right shape.
                expect(fake.calls).toEqual([
                    {
                        method: 'ext.aitest.network_requests',
                        params: {
                            isolateId: 'isolates/main-1',
                            limit: '25',
                            filter: '/monitors',
                        },
                    },
                ]);
            } finally {
                await cleanup();
            }
        });

        it('returns an empty-requests envelope gracefully when the Dart side returns no key', async () => {
            // Defensive path: if the interceptor was somehow not registered the
            // Dart ext should still answer with {requests: []}; we tolerate a
            // missing key by surfacing {requests: []} instead of throwing.
            const fake = makeFakeVmClient({
                'ext.aitest.network_requests': {},
            });
            const { client, cleanup } = await bootNetworkServer(fake.client);
            try {
                const result = await client.callTool({
                    name: 'flutter_network_requests',
                    arguments: {},
                });
                expect(result.isError).toBeFalsy();
                const content = result.content as ReadonlyArray<{ type: string; text: string }>;
                expect(JSON.parse(content[0]!.text)).toEqual({ requests: [] });
            } finally {
                await cleanup();
            }
        });

        it('rejects negative limit via zod (positive integer required)', async () => {
            const fake = makeFakeVmClient({});
            const { client, cleanup } = await bootNetworkServer(fake.client);
            try {
                // Input validation failures surface as an isError envelope from
                // the MCP SDK (the McpServer catches the zod McpError and wraps
                // it into a CallToolResult with isError: true); the client does
                // NOT throw on validation failures, matching the spec note that
                // tool errors are reported inside the result object so the LLM
                // can self-correct.
                const result = await client.callTool({
                    name: 'flutter_network_requests',
                    arguments: { limit: -1 },
                });
                expect(result.isError).toBe(true);
                const content = result.content as ReadonlyArray<{ type: string; text: string }>;
                expect(content[0]?.text).toContain('limit');
                expect(fake.calls).toEqual([]);
            } finally {
                await cleanup();
            }
        });

        it('wraps VM Service failures as an isError envelope', async () => {
            const erroringClient: LazyVmClient = {
                ...makeFakeVmClient({}).client,
                call: async <T>(): Promise<T> => {
                    throw new Error('VM Service unreachable');
                },
            };
            const { client, cleanup } = await bootNetworkServer(erroringClient);
            try {
                const result = await client.callTool({
                    name: 'flutter_network_requests',
                    arguments: {},
                });
                expect(result.isError).toBe(true);
                const content = result.content as ReadonlyArray<{ type: string; text: string }>;
                expect(content[0]?.text).toContain('VM Service unreachable');
            } finally {
                await cleanup();
            }
        });
    });

    // -----------------------------------------------------------------------
    // flutter_console_messages
    // -----------------------------------------------------------------------

    describe('flutter_console_messages', () => {
        it('calls ext.aitest.console_messages with {isolateId} only when no args supplied', async () => {
            const fake = makeFakeVmClient({
                'ext.aitest.console_messages': {
                    messages: [
                        {
                            level: 'INFO',
                            levelValue: 800,
                            message: 'boot complete',
                            loggerName: 'ai.test',
                            time: '2026-05-16T00:00:00.000Z',
                        },
                    ],
                },
            });
            const { client, cleanup } = await bootNetworkServer(fake.client);
            try {
                const result = await client.callTool({
                    name: 'flutter_console_messages',
                    arguments: {},
                });
                expect(result.isError).toBeFalsy();
                const content = result.content as ReadonlyArray<{ type: string; text: string }>;
                expect(JSON.parse(content[0]!.text)).toEqual({
                    messages: [
                        {
                            level: 'INFO',
                            levelValue: 800,
                            message: 'boot complete',
                            loggerName: 'ai.test',
                            time: '2026-05-16T00:00:00.000Z',
                        },
                    ],
                });
                expect(fake.calls).toEqual([
                    {
                        method: 'ext.aitest.console_messages',
                        params: { isolateId: 'isolates/main-1' },
                    },
                ]);
            } finally {
                await cleanup();
            }
        });

        it('forwards optional limit (stringified) and level to the extension', async () => {
            const fake = makeFakeVmClient({
                'ext.aitest.console_messages': { messages: [] },
            });
            const { client, cleanup } = await bootNetworkServer(fake.client);
            try {
                const result = await client.callTool({
                    name: 'flutter_console_messages',
                    arguments: { limit: 50, level: 'warning' },
                });
                expect(result.isError).toBeFalsy();
                expect(fake.calls).toEqual([
                    {
                        method: 'ext.aitest.console_messages',
                        params: {
                            isolateId: 'isolates/main-1',
                            limit: '50',
                            level: 'warning',
                        },
                    },
                ]);
            } finally {
                await cleanup();
            }
        });

        it('returns an empty-messages envelope gracefully when the Dart side returns no key', async () => {
            const fake = makeFakeVmClient({
                'ext.aitest.console_messages': {},
            });
            const { client, cleanup } = await bootNetworkServer(fake.client);
            try {
                const result = await client.callTool({
                    name: 'flutter_console_messages',
                    arguments: {},
                });
                expect(result.isError).toBeFalsy();
                const content = result.content as ReadonlyArray<{ type: string; text: string }>;
                expect(JSON.parse(content[0]!.text)).toEqual({ messages: [] });
            } finally {
                await cleanup();
            }
        });

        it('rejects unknown level via zod', async () => {
            const fake = makeFakeVmClient({});
            const { client, cleanup } = await bootNetworkServer(fake.client);
            try {
                const result = await client.callTool({
                    name: 'flutter_console_messages',
                    arguments: { level: 'banana' },
                });
                expect(result.isError).toBe(true);
                const content = result.content as ReadonlyArray<{ type: string; text: string }>;
                expect(content[0]?.text).toContain('level');
                expect(fake.calls).toEqual([]);
            } finally {
                await cleanup();
            }
        });
    });

    // -----------------------------------------------------------------------
    // flutter_mock_http
    // -----------------------------------------------------------------------

    describe('flutter_mock_http', () => {
        it('calls ext.aitest.mock_http with {isolateId, pattern, status, body} stringified', async () => {
            const fake = makeFakeVmClient({
                'ext.aitest.mock_http': { ok: true, pattern: '/monitors' },
            });
            const { client, cleanup } = await bootNetworkServer(fake.client);
            try {
                const result = await client.callTool({
                    name: 'flutter_mock_http',
                    arguments: {
                        pattern: '/monitors',
                        status: 200,
                        body: '{"data":[]}',
                    },
                });
                expect(result.isError).toBeFalsy();
                const content = result.content as ReadonlyArray<{ type: string; text: string }>;
                expect(JSON.parse(content[0]!.text)).toEqual({
                    ok: true,
                    pattern: '/monitors',
                });
                // Status MUST arrive as a string because ServiceExtension params
                // are Map<String,String>; the Dart handler int.tryParses it.
                expect(fake.calls).toEqual([
                    {
                        method: 'ext.aitest.mock_http',
                        params: {
                            isolateId: 'isolates/main-1',
                            pattern: '/monitors',
                            status: '200',
                            body: '{"data":[]}',
                        },
                    },
                ]);
            } finally {
                await cleanup();
            }
        });

        it('forwards optional contentType and JSON-encodes headers map', async () => {
            const fake = makeFakeVmClient({
                'ext.aitest.mock_http': { ok: true, pattern: '/x' },
            });
            const { client, cleanup } = await bootNetworkServer(fake.client);
            try {
                await client.callTool({
                    name: 'flutter_mock_http',
                    arguments: {
                        pattern: '/x',
                        status: 201,
                        body: '',
                        contentType: 'application/json',
                        headers: { 'X-Test': '1' },
                    },
                });
                // headers must be JSON-encoded so the Dart handler can jsonDecode
                // back into a Map<String,String>.
                expect(fake.calls).toEqual([
                    {
                        method: 'ext.aitest.mock_http',
                        params: {
                            isolateId: 'isolates/main-1',
                            pattern: '/x',
                            status: '201',
                            body: '',
                            contentType: 'application/json',
                            headers: '{"X-Test":"1"}',
                        },
                    },
                ]);
            } finally {
                await cleanup();
            }
        });

        it('rejects empty pattern via zod', async () => {
            const fake = makeFakeVmClient({});
            const { client, cleanup } = await bootNetworkServer(fake.client);
            try {
                const result = await client.callTool({
                    name: 'flutter_mock_http',
                    arguments: { pattern: '', status: 200, body: '' },
                });
                expect(result.isError).toBe(true);
                const content = result.content as ReadonlyArray<{ type: string; text: string }>;
                expect(content[0]?.text).toContain('pattern');
                expect(fake.calls).toEqual([]);
            } finally {
                await cleanup();
            }
        });

        it('rejects out-of-range status via zod', async () => {
            const fake = makeFakeVmClient({});
            const { client, cleanup } = await bootNetworkServer(fake.client);
            try {
                const result = await client.callTool({
                    name: 'flutter_mock_http',
                    arguments: { pattern: '/x', status: 99, body: '' },
                });
                expect(result.isError).toBe(true);
                const content = result.content as ReadonlyArray<{ type: string; text: string }>;
                expect(content[0]?.text).toContain('status');
                expect(fake.calls).toEqual([]);
            } finally {
                await cleanup();
            }
        });

        it('wraps VM Service failures as an isError envelope', async () => {
            const erroringClient: LazyVmClient = {
                ...makeFakeVmClient({}).client,
                call: async <T>(): Promise<T> => {
                    throw new Error('mock rule rejected');
                },
            };
            const { client, cleanup } = await bootNetworkServer(erroringClient);
            try {
                const result = await client.callTool({
                    name: 'flutter_mock_http',
                    arguments: { pattern: '/x', status: 200, body: '' },
                });
                expect(result.isError).toBe(true);
                const content = result.content as ReadonlyArray<{ type: string; text: string }>;
                expect(content[0]?.text).toContain('mock rule rejected');
            } finally {
                await cleanup();
            }
        });
    });
});
