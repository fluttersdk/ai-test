import { describe, expect, it, vi } from 'vitest';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';

import { registerSnapshotTools } from '../../src/tools/snapshot.js';
import type { LazyVmClient } from '../../src/server.js';

/**
 * Build a fake `LazyVmClient` that records every VM Service call and replies
 * with a scripted response per method. Mirrors the shape expected by
 * `registerSnapshotTools` so the tool wrappers run end-to-end without a real
 * WebSocket connection.
 */
interface CallRecord {
    method: string;
    params: object | undefined;
}

interface FakeVm {
    client: LazyVmClient;
    calls: ReadonlyArray<CallRecord>;
}

function buildFakeVmClient(
    responder: (method: string, params: object | undefined) => unknown,
): FakeVm {
    const calls: CallRecord[] = [];
    const client: LazyVmClient = {
        get isConnected(): boolean {
            return true;
        },
        connect: async (): Promise<void> => undefined,
        disconnect: async (): Promise<void> => undefined,
        getMainIsolateId: async (): Promise<string> => 'isolates/main',
        getRootLibId: async (_isolateId: string): Promise<string> =>
            'libraries/rootlib',
        clearRootLibCacheForTests: (): void => undefined,
        call: async <T>(method: string, params?: object): Promise<T> => {
            calls.push({ method, params });
            return responder(method, params) as T;
        },
    };
    return { client, calls };
}

/**
 * Boot an `McpServer` with only the snapshot-group tools registered (no other
 * tool surface), wired to an in-process `Client` via linked transports. Returns
 * helpers for asserting against the fake VM and cleaning up.
 */
async function bootServerWithSnapshotTools(
    responder: (method: string, params: object | undefined) => unknown,
): Promise<{
    client: Client;
    vmCalls: ReadonlyArray<CallRecord>;
    cleanup: () => Promise<void>;
}> {
    const fake = buildFakeVmClient(responder);
    const server = new McpServer({
        name: 'snapshot-tools-test',
        version: '0.0.0',
    });
    registerSnapshotTools(server, fake.client);

    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const client = new Client(
        { name: 'snapshot-tools-test-client', version: '0.0.0' },
        { capabilities: {} },
    );
    await Promise.all([
        server.connect(serverTransport),
        client.connect(clientTransport),
    ]);

    return {
        client,
        vmCalls: fake.calls,
        cleanup: async (): Promise<void> => {
            await client.close();
            await server.close();
        },
    };
}

describe('registerSnapshotTools()', () => {
    it('registers all 5 tools (snapshot, screenshot, evaluate, wait_for, wait_for_request)',
        async () => {
            const { client, cleanup } = await bootServerWithSnapshotTools(() => ({}));
            try {
                const { tools } = await client.listTools();
                const names = tools.map((t) => t.name).sort();
                expect(names).toEqual([
                    'flutter_evaluate',
                    'flutter_screenshot',
                    'flutter_snapshot',
                    'flutter_wait_for',
                    'flutter_wait_for_request',
                ]);
            } finally {
                await cleanup();
            }
        });

    describe('flutter_snapshot', () => {
        it('calls ext.aitest.snapshot and returns YAML text content', async () => {
            const yaml = '- button "Click" [ref=e1]\n';
            const { client, vmCalls, cleanup } = await bootServerWithSnapshotTools(
                (method) => {
                    expect(method).toBe('ext.aitest.snapshot');
                    return { snapshot: yaml, groupId: 'snapshot-12345' };
                },
            );
            try {
                const result = await client.callTool({
                    name: 'flutter_snapshot',
                    arguments: {},
                });
                expect(result.isError).toBeFalsy();
                const content = result.content as ReadonlyArray<{
                    type: string;
                    text: string;
                }>;
                expect(content).toHaveLength(1);
                expect(content[0]?.type).toBe('text');
                expect(content[0]?.text).toBe(yaml);
                // groupId is preserved server-side but not surfaced in output.
                expect(content[0]?.text).not.toContain('groupId');
                expect(vmCalls).toHaveLength(1);
                expect(vmCalls[0]?.method).toBe('ext.aitest.snapshot');
                expect(vmCalls[0]?.params).toMatchObject({ isolateId: 'isolates/main' });
            } finally {
                await cleanup();
            }
        });

        it('forwards optional depth parameter to the extension as a string', async () => {
            const { client, vmCalls, cleanup } = await bootServerWithSnapshotTools(
                () => ({ snapshot: '- text "x"\n', groupId: 'g1' }),
            );
            try {
                await client.callTool({
                    name: 'flutter_snapshot',
                    arguments: { depth: 3 },
                });
                expect(vmCalls[0]?.params).toMatchObject({
                    isolateId: 'isolates/main',
                    depth: '3',
                });
            } finally {
                await cleanup();
            }
        });

        it('returns isError envelope when ext.aitest.snapshot fails', async () => {
            const { client, cleanup } = await bootServerWithSnapshotTools(() => {
                throw new Error('semantics tree missing');
            });
            try {
                const result = await client.callTool({
                    name: 'flutter_snapshot',
                    arguments: {},
                });
                expect(result.isError).toBe(true);
                const content = result.content as ReadonlyArray<{
                    type: string;
                    text: string;
                }>;
                expect(content[0]?.type).toBe('text');
                expect(content[0]?.text).toContain('flutter_snapshot');
                expect(content[0]?.text).toContain('semantics tree missing');
            } finally {
                await cleanup();
            }
        });

        it('produces parseable snapshot text containing ref tokens (integration)', async () => {
            const yamlBlob =
                '- text "Welcome"\n- button "Sign in" [ref=e1]\n- textbox "Email" [ref=e2]\n';
            const { client, cleanup } = await bootServerWithSnapshotTools(() => ({
                snapshot: yamlBlob,
                groupId: 'snapshot-int-1',
            }));
            try {
                const result = await client.callTool({
                    name: 'flutter_snapshot',
                    arguments: {},
                });
                const text = (
                    result.content as ReadonlyArray<{ type: string; text: string }>
                )[0]?.text;
                expect(text).toBeDefined();
                // Smoke: agent should see at least two ref tokens to act on.
                const refMatches = text!.match(/\[ref=e\d+\]/g) ?? [];
                expect(refMatches.length).toBeGreaterThanOrEqual(2);
                // The structural lines stay intact (no JSON wrapping).
                expect(text).toContain('- text "Welcome"');
                expect(text).toContain('- button "Sign in"');
            } finally {
                await cleanup();
            }
        });
    });

    describe('flutter_screenshot', () => {
        // 1×1 transparent PNG, base64-encoded. Decodes to 67 bytes of valid PNG.
        const ONE_BY_ONE_PNG_BASE64 =
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

        it('calls ext.aitest.screenshot and returns image content with PNG mimeType', async () => {
            const { client, vmCalls, cleanup } = await bootServerWithSnapshotTools(
                (method) => {
                    expect(method).toBe('ext.aitest.screenshot');
                    return {
                        format: 'png',
                        base64: ONE_BY_ONE_PNG_BASE64,
                        width: 1,
                        height: 1,
                    };
                },
            );
            try {
                const result = await client.callTool({
                    name: 'flutter_screenshot',
                    arguments: { format: 'png' },
                });
                expect(result.isError).toBeFalsy();
                const content = result.content as ReadonlyArray<{
                    type: string;
                    mimeType?: string;
                    data?: string;
                }>;
                expect(content).toHaveLength(1);
                expect(content[0]?.type).toBe('image');
                expect(content[0]?.mimeType).toBe('image/png');
                expect(content[0]?.data).toBe(ONE_BY_ONE_PNG_BASE64);
                expect(vmCalls[0]?.params).toMatchObject({
                    isolateId: 'isolates/main',
                    format: 'png',
                });
            } finally {
                await cleanup();
            }
        });

        it('returns image/jpeg mimeType for JPEG response', async () => {
            const { client, cleanup } = await bootServerWithSnapshotTools(() => ({
                format: 'jpeg',
                base64: 'AAAA',
                width: 800,
                height: 600,
            }));
            try {
                const result = await client.callTool({
                    name: 'flutter_screenshot',
                    arguments: { format: 'jpeg', quality: 80 },
                });
                expect(result.isError).toBeFalsy();
                const content = result.content as ReadonlyArray<{
                    type: string;
                    mimeType?: string;
                    data?: string;
                }>;
                expect(content[0]?.type).toBe('image');
                expect(content[0]?.mimeType).toBe('image/jpeg');
                expect(content[0]?.data).toBe('AAAA');
            } finally {
                await cleanup();
            }
        });

        it('passes format + quality through to the extension as strings', async () => {
            const { client, vmCalls, cleanup } = await bootServerWithSnapshotTools(
                () => ({
                    format: 'jpeg',
                    base64: 'AA',
                    width: 1,
                    height: 1,
                }),
            );
            try {
                await client.callTool({
                    name: 'flutter_screenshot',
                    arguments: { format: 'jpeg', quality: 50 },
                });
                expect(vmCalls[0]?.params).toMatchObject({
                    isolateId: 'isolates/main',
                    format: 'jpeg',
                    quality: '50',
                });
            } finally {
                await cleanup();
            }
        });

        it('forwards ref parameter when present', async () => {
            const { client, vmCalls, cleanup } = await bootServerWithSnapshotTools(
                () => ({
                    format: 'png',
                    base64: 'AA',
                    width: 1,
                    height: 1,
                }),
            );
            try {
                await client.callTool({
                    name: 'flutter_screenshot',
                    arguments: { ref: 'e7' },
                });
                expect(vmCalls[0]?.params).toMatchObject({
                    isolateId: 'isolates/main',
                    ref: 'e7',
                });
            } finally {
                await cleanup();
            }
        });

        it('returns base64 that decodes to a valid byte buffer (integration)', async () => {
            const { client, cleanup } = await bootServerWithSnapshotTools(() => ({
                format: 'png',
                base64: ONE_BY_ONE_PNG_BASE64,
                width: 1,
                height: 1,
            }));
            try {
                const result = await client.callTool({
                    name: 'flutter_screenshot',
                    arguments: {},
                });
                const content = result.content as ReadonlyArray<{
                    type: string;
                    data?: string;
                }>;
                const decoded = Buffer.from(content[0]?.data ?? '', 'base64');
                // PNG signature: 89 50 4E 47 0D 0A 1A 0A.
                expect(decoded[0]).toBe(0x89);
                expect(decoded[1]).toBe(0x50);
                expect(decoded[2]).toBe(0x4e);
                expect(decoded[3]).toBe(0x47);
            } finally {
                await cleanup();
            }
        });

        it('returns isError envelope when ext.aitest.screenshot fails', async () => {
            const { client, cleanup } = await bootServerWithSnapshotTools(() => {
                throw new Error('boundary missing');
            });
            try {
                const result = await client.callTool({
                    name: 'flutter_screenshot',
                    arguments: {},
                });
                expect(result.isError).toBe(true);
                const content = result.content as ReadonlyArray<{
                    type: string;
                    text?: string;
                }>;
                expect(content[0]?.type).toBe('text');
                expect(content[0]?.text).toContain('flutter_screenshot');
                expect(content[0]?.text).toContain('boundary missing');
            } finally {
                await cleanup();
            }
        });
    });

    describe('flutter_evaluate', () => {
        it('calls VM Service evaluate with rootLib targetId and returns JSON text', async () => {
            const evalResult = {
                type: '@Instance',
                kind: 'String',
                valueAsString: '42',
            };
            const { client, vmCalls, cleanup } = await bootServerWithSnapshotTools(
                (method, params) => {
                    expect(method).toBe('evaluate');
                    expect(params).toMatchObject({
                        isolateId: 'isolates/main',
                        targetId: 'libraries/rootlib',
                        expression: '1 + 1',
                    });
                    return evalResult;
                },
            );
            try {
                const result = await client.callTool({
                    name: 'flutter_evaluate',
                    arguments: { expression: '1 + 1' },
                });
                expect(result.isError).toBeFalsy();
                const content = result.content as ReadonlyArray<{
                    type: string;
                    text: string;
                }>;
                expect(content[0]?.type).toBe('text');
                expect(JSON.parse(content[0]!.text)).toEqual(evalResult);
                expect(vmCalls).toHaveLength(1);
            } finally {
                await cleanup();
            }
        });

        it('returns isError envelope when expression evaluation fails', async () => {
            const { client, cleanup } = await bootServerWithSnapshotTools(() => {
                throw new Error('Compilation error: expected expression');
            });
            try {
                const result = await client.callTool({
                    name: 'flutter_evaluate',
                    arguments: { expression: 'not valid !!' },
                });
                expect(result.isError).toBe(true);
                const content = result.content as ReadonlyArray<{
                    type: string;
                    text?: string;
                }>;
                expect(content[0]?.type).toBe('text');
                expect(content[0]?.text).toContain('flutter_evaluate');
                expect(content[0]?.text).toContain('Compilation error');
            } finally {
                await cleanup();
            }
        });

        it('rejects empty expression at the schema layer (isError envelope)', async () => {
            const { client, vmCalls, cleanup } = await bootServerWithSnapshotTools(
                () => ({}),
            );
            try {
                const result = await client.callTool({
                    name: 'flutter_evaluate',
                    arguments: { expression: '' },
                });
                expect(result.isError).toBe(true);
                const content = result.content as ReadonlyArray<{
                    type: string;
                    text?: string;
                }>;
                expect(content[0]?.text).toContain('expression');
                // Critical: schema rejection must NOT reach the VM Service.
                expect(vmCalls).toHaveLength(0);
            } finally {
                await cleanup();
            }
        });
    });

    describe('flutter_wait_for', () => {
        it('calls ext.aitest.wait_for with the supplied predicate', async () => {
            const { client, vmCalls, cleanup } = await bootServerWithSnapshotTools(
                (method) => {
                    expect(method).toBe('ext.aitest.wait_for');
                    return { matched: true, elapsedMs: 420 };
                },
            );
            try {
                const result = await client.callTool({
                    name: 'flutter_wait_for',
                    arguments: { text: 'Loaded', timeoutMs: 2000 },
                });
                expect(result.isError).toBeFalsy();
                const content = result.content as ReadonlyArray<{
                    type: string;
                    text: string;
                }>;
                expect(content[0]?.type).toBe('text');
                expect(JSON.parse(content[0]!.text)).toEqual({
                    matched: true,
                    elapsedMs: 420,
                });
                expect(vmCalls[0]?.params).toMatchObject({
                    isolateId: 'isolates/main',
                    text: 'Loaded',
                    timeoutMs: '2000',
                });
            } finally {
                await cleanup();
            }
        });

        it('forwards textGone and expression predicates', async () => {
            const { client, vmCalls, cleanup } = await bootServerWithSnapshotTools(
                () => ({ matched: true, elapsedMs: 100 }),
            );
            try {
                await client.callTool({
                    name: 'flutter_wait_for',
                    arguments: { textGone: 'Loading...' },
                });
                expect(vmCalls[0]?.params).toMatchObject({
                    isolateId: 'isolates/main',
                    textGone: 'Loading...',
                });
                expect(vmCalls[0]?.params).not.toHaveProperty('text');
                expect(vmCalls[0]?.params).not.toHaveProperty('expression');
            } finally {
                await cleanup();
            }
        });

        it('returns the timeout envelope verbatim when ext returns matched=false', async () => {
            const { client, cleanup } = await bootServerWithSnapshotTools(() => ({
                matched: false,
                reason: 'timeout',
            }));
            try {
                const result = await client.callTool({
                    name: 'flutter_wait_for',
                    arguments: { text: 'NeverAppears', timeoutMs: 200 },
                });
                expect(result.isError).toBeFalsy();
                const content = result.content as ReadonlyArray<{
                    type: string;
                    text: string;
                }>;
                expect(JSON.parse(content[0]!.text)).toEqual({
                    matched: false,
                    reason: 'timeout',
                });
            } finally {
                await cleanup();
            }
        });

        it('returns isError envelope when ext.aitest.wait_for throws', async () => {
            const { client, cleanup } = await bootServerWithSnapshotTools(() => {
                throw new Error('wait_for requires text|textGone|expression');
            });
            try {
                const result = await client.callTool({
                    name: 'flutter_wait_for',
                    arguments: {},
                });
                expect(result.isError).toBe(true);
                const content = result.content as ReadonlyArray<{
                    type: string;
                    text?: string;
                }>;
                expect(content[0]?.text).toContain('flutter_wait_for');
            } finally {
                await cleanup();
            }
        });
    });

    describe('isolate lookup', () => {
        it('always delegates to the live vmClient so device-target switches stay in sync',
            async () => {
            // The previous implementation cached the first isolate id under
            // closure forever. After a device-target switch (chrome → macos),
            // the lazy wrapper in server.ts rebuilds the underlying VM client
            // against the new state.json URI, but the stale tool-context
            // cache still pointed at the dead chrome isolate — every
            // downstream ext.aitest.* call then failed with VM Service
            // "Invalid params" because that isolate no longer existed.
            //
            // The fix is to always read the isolate id from the live client.
            // The lookup itself is one local-WebSocket `getVM` RPC, sub-ms on
            // Flutter web, low-ms on USB/wireless mobile — the trade is
            // correctness across device sessions for negligible per-call cost.
            const calls: CallRecord[] = [];
            let isolateLookupCount = 0;
            const fakeClient: LazyVmClient = {
                get isConnected(): boolean {
                    return true;
                },
                connect: async (): Promise<void> => undefined,
                disconnect: async (): Promise<void> => undefined,
                getMainIsolateId: async (): Promise<string> => {
                    isolateLookupCount += 1;
                    return 'isolates/main';
                },
                getRootLibId: async (): Promise<string> => 'libraries/rootlib',
                clearRootLibCacheForTests: (): void => undefined,
                call: async <T>(method: string, params?: object): Promise<T> => {
                    calls.push({ method, params });
                    return { snapshot: '', groupId: 'g' } as unknown as T;
                },
            };

            const server = new McpServer({
                name: 'isolate-cache-test',
                version: '0.0.0',
            });
            registerSnapshotTools(server, fakeClient);

            const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
            const client = new Client(
                { name: 'isolate-cache-test-client', version: '0.0.0' },
                { capabilities: {} },
            );
            await Promise.all([
                server.connect(serverTransport),
                client.connect(clientTransport),
            ]);

            try {
                await client.callTool({ name: 'flutter_snapshot', arguments: {} });
                await client.callTool({ name: 'flutter_snapshot', arguments: {} });
                await client.callTool({ name: 'flutter_snapshot', arguments: {} });
                // Every tool call must consult the live vmClient — proves no
                // stale closure-level cache shadows the underlying lookup.
                expect(isolateLookupCount).toBe(3);
                expect(calls).toHaveLength(3);
            } finally {
                await client.close();
                await server.close();
            }
        });
    });
});

/**
 * Trivial smoke check that we did not accidentally leak a module-level
 * console.log (which would corrupt the JSON-RPC stream on stdio).
 */
describe('snapshot.ts module hygiene', () => {
    it('does not write to stdout during registration', async () => {
        const logSpy = vi.spyOn(console, 'log').mockImplementation(() => undefined);
        try {
            const fake = buildFakeVmClient(() => ({
                snapshot: '',
                groupId: 'g',
            }));
            const server = new McpServer({ name: 'hygiene', version: '0.0.0' });
            registerSnapshotTools(server, fake.client);
            await server.close();
            expect(logSpy).not.toHaveBeenCalled();
        } finally {
            logSpy.mockRestore();
        }
    });
});
