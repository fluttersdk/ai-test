import { describe, expect, it, beforeEach } from 'vitest';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { registerInteractionTools } from '../../src/tools/interaction.js';
import type { LazyVmClient } from '../../src/server.js';

/**
 * Fake `LazyVmClient` that records every `call(method, params)` invocation and
 * returns a canned response keyed by method name. Used by the per-tool tests
 * below to assert the wrapper translates MCP tool args into the correct
 * `ext.aitest.*` VM Service call without spinning up a WebSocket.
 *
 * `getMainIsolateId` resolves to a fixed string so the wrappers can prepend
 * `isolateId` to every call as required by the VM Service protocol.
 */
interface FakeCall {
    readonly method: string;
    readonly params: Record<string, unknown>;
}

interface FakeVmClient extends LazyVmClient {
    readonly calls: ReadonlyArray<FakeCall>;
    setResponse(method: string, response: unknown): void;
    setError(method: string, error: Error): void;
}

function createFakeVmClient(): FakeVmClient {
    const calls: FakeCall[] = [];
    const responses = new Map<string, unknown>();
    const errors = new Map<string, Error>();
    const isolateId = 'isolates/123';

    const client: FakeVmClient = {
        get calls(): ReadonlyArray<FakeCall> {
            return calls;
        },
        setResponse(method: string, response: unknown): void {
            responses.set(method, response);
        },
        setError(method: string, error: Error): void {
            errors.set(method, error);
        },
        get isConnected(): boolean {
            return true;
        },
        connect(): Promise<void> {
            return Promise.resolve();
        },
        disconnect(): Promise<void> {
            return Promise.resolve();
        },
        getMainIsolateId(): Promise<string> {
            return Promise.resolve(isolateId);
        },
        getRootLibId(_isolateId: string): Promise<string> {
            return Promise.resolve('libraries/root');
        },
        clearRootLibCacheForTests(): void {
            // no-op
        },
        call<T>(method: string, params?: object): Promise<T> {
            calls.push({
                method,
                params: (params ?? {}) as Record<string, unknown>,
            });
            const err = errors.get(method);
            if (err) return Promise.reject(err);
            const response = responses.get(method) ?? {};
            return Promise.resolve(response as T);
        },
    };

    return client;
}

/**
 * Boot an in-memory MCP server with only the interaction tool group registered
 * and return a connected client. Tests interact via the public `callTool` API,
 * which exercises the full zod-validation + handler path.
 */
async function bootServerWithInteraction(): Promise<{
    readonly client: Client;
    readonly vmClient: FakeVmClient;
    readonly cleanup: () => Promise<void>;
}> {
    const vmClient = createFakeVmClient();
    const server = new McpServer({
        name: 'ai-test-interaction-test',
        version: '0.0.0',
    });
    registerInteractionTools(server, vmClient);

    const [clientTransport, serverTransport] =
        InMemoryTransport.createLinkedPair();
    const client = new Client(
        {
            name: 'interaction-test-client',
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
        vmClient,
        cleanup: async (): Promise<void> => {
            await client.close();
            await server.close();
        },
    };
}

const INTERACTION_TOOL_NAMES: ReadonlyArray<string> = [
    'flutter_tap',
    'flutter_type',
    'flutter_press_key',
    'flutter_hover',
    'flutter_drag',
    'flutter_select_option',
    'flutter_file_upload',
];

describe('registerInteractionTools()', () => {
    it('registers all 7 interaction tools on the McpServer', async () => {
        const { client, cleanup } = await bootServerWithInteraction();
        try {
            const { tools } = await client.listTools();
            const names = tools.map((t) => t.name).sort();
            expect(names).toEqual([...INTERACTION_TOOL_NAMES].sort());
            expect(tools).toHaveLength(7);
        } finally {
            await cleanup();
        }
    });

    it('declares a non-empty description for every interaction tool', async () => {
        const { client, cleanup } = await bootServerWithInteraction();
        try {
            const { tools } = await client.listTools();
            for (const tool of tools) {
                expect(
                    tool.description,
                    `description for ${tool.name}`,
                ).toBeTruthy();
            }
        } finally {
            await cleanup();
        }
    });
});

describe('flutter_tap', () => {
    let ctx: Awaited<ReturnType<typeof bootServerWithInteraction>>;

    beforeEach(async () => {
        ctx = await bootServerWithInteraction();
    });

    it('calls ext.aitest.tap with isolateId + ref', async () => {
        ctx.vmClient.setResponse('ext.aitest.tap', { ref: 'e3' });

        const result = await ctx.client.callTool({
            name: 'flutter_tap',
            arguments: { ref: 'e3' },
        });

        expect(ctx.vmClient.calls).toHaveLength(1);
        expect(ctx.vmClient.calls[0]?.method).toBe('ext.aitest.tap');
        expect(ctx.vmClient.calls[0]?.params).toEqual({
            isolateId: 'isolates/123',
            ref: 'e3',
        });
        const content = result.content as ReadonlyArray<{
            type: string;
            text?: string;
        }>;
        expect(content[0]?.type).toBe('text');
        expect(content[0]?.text).toBe(JSON.stringify({ ref: 'e3' }));

        await ctx.cleanup();
    });

    it('returns isError envelope when VM Service rejects', async () => {
        ctx.vmClient.setError(
            'ext.aitest.tap',
            new Error('ref "e99" not found'),
        );

        const result = await ctx.client.callTool({
            name: 'flutter_tap',
            arguments: { ref: 'e99' },
        });

        expect(result.isError).toBe(true);
        const content = result.content as ReadonlyArray<{
            type: string;
            text?: string;
        }>;
        expect(content[0]?.type).toBe('text');
        expect(content[0]?.text).toContain('ref "e99" not found');

        await ctx.cleanup();
    });

    it('returns isError envelope when ref is missing (zod validation)', async () => {
        const result = await ctx.client.callTool({
            name: 'flutter_tap',
            arguments: {},
        });

        expect(result.isError).toBe(true);
        expect(ctx.vmClient.calls).toHaveLength(0);
        const content = result.content as ReadonlyArray<{
            type: string;
            text?: string;
        }>;
        expect(content[0]?.text).toContain('ref');

        await ctx.cleanup();
    });
});

describe('flutter_type', () => {
    let ctx: Awaited<ReturnType<typeof bootServerWithInteraction>>;

    beforeEach(async () => {
        ctx = await bootServerWithInteraction();
    });

    it('calls ext.aitest.type with isolateId + ref + text', async () => {
        ctx.vmClient.setResponse('ext.aitest.type', { text: 'hello@x.io' });

        const result = await ctx.client.callTool({
            name: 'flutter_type',
            arguments: { ref: 'e5', text: 'hello@x.io' },
        });

        expect(ctx.vmClient.calls[0]?.method).toBe('ext.aitest.type');
        expect(ctx.vmClient.calls[0]?.params).toEqual({
            isolateId: 'isolates/123',
            ref: 'e5',
            text: 'hello@x.io',
        });
        const content = result.content as ReadonlyArray<{
            type: string;
            text?: string;
        }>;
        expect(content[0]?.text).toBe(
            JSON.stringify({ text: 'hello@x.io' }),
        );

        await ctx.cleanup();
    });

    it('accepts empty text string (clearing a field)', async () => {
        ctx.vmClient.setResponse('ext.aitest.type', { text: '' });

        await ctx.client.callTool({
            name: 'flutter_type',
            arguments: { ref: 'e5', text: '' },
        });

        expect(ctx.vmClient.calls[0]?.params).toEqual({
            isolateId: 'isolates/123',
            ref: 'e5',
            text: '',
        });

        await ctx.cleanup();
    });
});

describe('flutter_press_key', () => {
    let ctx: Awaited<ReturnType<typeof bootServerWithInteraction>>;

    beforeEach(async () => {
        ctx = await bootServerWithInteraction();
    });

    it('calls ext.aitest.press_key with key only when no modifiers', async () => {
        ctx.vmClient.setResponse('ext.aitest.press_key', {
            ok: true,
            key: 'Enter',
        });

        const result = await ctx.client.callTool({
            name: 'flutter_press_key',
            arguments: { key: 'Enter' },
        });

        expect(ctx.vmClient.calls[0]?.method).toBe('ext.aitest.press_key');
        expect(ctx.vmClient.calls[0]?.params).toEqual({
            isolateId: 'isolates/123',
            key: 'Enter',
        });
        const content = result.content as ReadonlyArray<{
            type: string;
            text?: string;
        }>;
        expect(content[0]?.text).toBe(
            JSON.stringify({ ok: true, key: 'Enter' }),
        );

        await ctx.cleanup();
    });

    it('forwards modifiers as comma-separated string when provided', async () => {
        ctx.vmClient.setResponse('ext.aitest.press_key', {
            ok: true,
            key: 'a',
        });

        await ctx.client.callTool({
            name: 'flutter_press_key',
            arguments: { key: 'a', modifiers: ['Control', 'Shift'] },
        });

        // Dart-side handler reads `Map<String, String>`; modifiers go over the
        // wire as a single comma-joined string the Dart side splits.
        expect(ctx.vmClient.calls[0]?.params).toEqual({
            isolateId: 'isolates/123',
            key: 'a',
            modifiers: 'Control,Shift',
        });

        await ctx.cleanup();
    });
});

describe('flutter_hover', () => {
    let ctx: Awaited<ReturnType<typeof bootServerWithInteraction>>;

    beforeEach(async () => {
        ctx = await bootServerWithInteraction();
    });

    it('calls ext.aitest.hover with isolateId + ref', async () => {
        ctx.vmClient.setResponse('ext.aitest.hover', { ref: 'e7' });

        await ctx.client.callTool({
            name: 'flutter_hover',
            arguments: { ref: 'e7' },
        });

        expect(ctx.vmClient.calls[0]?.method).toBe('ext.aitest.hover');
        expect(ctx.vmClient.calls[0]?.params).toEqual({
            isolateId: 'isolates/123',
            ref: 'e7',
        });

        await ctx.cleanup();
    });
});

describe('flutter_drag', () => {
    let ctx: Awaited<ReturnType<typeof bootServerWithInteraction>>;

    beforeEach(async () => {
        ctx = await bootServerWithInteraction();
    });

    it('calls ext.aitest.drag with startRef + endRef', async () => {
        ctx.vmClient.setResponse('ext.aitest.drag', {
            startRef: 'e1',
            endRef: 'e2',
        });

        const result = await ctx.client.callTool({
            name: 'flutter_drag',
            arguments: { startRef: 'e1', endRef: 'e2' },
        });

        expect(ctx.vmClient.calls[0]?.method).toBe('ext.aitest.drag');
        expect(ctx.vmClient.calls[0]?.params).toEqual({
            isolateId: 'isolates/123',
            startRef: 'e1',
            endRef: 'e2',
        });
        const content = result.content as ReadonlyArray<{
            type: string;
            text?: string;
        }>;
        expect(content[0]?.text).toBe(
            JSON.stringify({ startRef: 'e1', endRef: 'e2' }),
        );

        await ctx.cleanup();
    });

    it('returns isError envelope when endRef is missing (zod validation)', async () => {
        const result = await ctx.client.callTool({
            name: 'flutter_drag',
            arguments: { startRef: 'e1' },
        });

        expect(result.isError).toBe(true);
        expect(ctx.vmClient.calls).toHaveLength(0);
        const content = result.content as ReadonlyArray<{
            type: string;
            text?: string;
        }>;
        expect(content[0]?.text).toContain('endRef');

        await ctx.cleanup();
    });
});

describe('flutter_select_option', () => {
    let ctx: Awaited<ReturnType<typeof bootServerWithInteraction>>;

    beforeEach(async () => {
        ctx = await bootServerWithInteraction();
    });

    it('calls ext.aitest.select_option with isolateId + ref + value', async () => {
        ctx.vmClient.setResponse('ext.aitest.select_option', {
            selected: true,
            value: 'eu-west-1',
        });

        const result = await ctx.client.callTool({
            name: 'flutter_select_option',
            arguments: { ref: 'e9', value: 'eu-west-1' },
        });

        expect(ctx.vmClient.calls[0]?.method).toBe(
            'ext.aitest.select_option',
        );
        expect(ctx.vmClient.calls[0]?.params).toEqual({
            isolateId: 'isolates/123',
            ref: 'e9',
            value: 'eu-west-1',
        });
        const content = result.content as ReadonlyArray<{
            type: string;
            text?: string;
        }>;
        expect(content[0]?.text).toBe(
            JSON.stringify({ selected: true, value: 'eu-west-1' }),
        );

        await ctx.cleanup();
    });
});

describe('flutter_file_upload', () => {
    let ctx: Awaited<ReturnType<typeof bootServerWithInteraction>>;

    beforeEach(async () => {
        ctx = await bootServerWithInteraction();
    });

    it('returns the V3.1-deferred isError envelope without calling the VM Service', async () => {
        const result = await ctx.client.callTool({
            name: 'flutter_file_upload',
            arguments: { ref: 'e10', path: '/tmp/fixture.png' },
        });

        expect(result.isError).toBe(true);
        expect(ctx.vmClient.calls).toHaveLength(0);
        const content = result.content as ReadonlyArray<{
            type: string;
            text?: string;
        }>;
        expect(content[0]?.type).toBe('text');
        expect(content[0]?.text).toContain('deferred to V3.1');
        expect(content[0]?.text).toContain('browser File API');

        await ctx.cleanup();
    });
});
