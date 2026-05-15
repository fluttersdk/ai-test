import { beforeEach, describe, expect, it, vi } from 'vitest';
import { McpError } from '@modelcontextprotocol/sdk/types.js';
import {
    evaluateDartTool,
    getRoutesTool,
    getWidgetTreeTool,
    VALIDATING_HANDLERS,
} from '../src/tools/index.js';
import { VmServiceError } from '../src/vm_service_client.js';
import type { ToolContext } from '../src/tools/index.js';
import type { IsolateInfo } from '../src/types.js';

interface FakeClient {
    isolateId: string;
    rootLibId: string;
    calls: Array<{ method: string; params?: unknown }>;
    canned: Map<string, unknown>;
}

function fakeClient(canned: Record<string, unknown> = {}): FakeClient {
    return {
        isolateId: 'isolates/abc',
        rootLibId: 'isolates/abc/libraries/9',
        calls: [],
        canned: new Map(Object.entries(canned)),
    };
}

function context(client: FakeClient): ToolContext {
    const call = async <T = unknown>(method: string, params?: object): Promise<T> => {
        client.calls.push({ method, params });
        if (!client.canned.has(method)) {
            throw new VmServiceError(method, -32000, `no canned response for ${method}`);
        }
        return client.canned.get(method) as T;
    };
    // Per-fake rootLib cache mirroring VmServiceClient's behaviour, so tests
    // can assert getIsolate is invoked exactly once across multiple evaluate calls.
    const rootLibCache = new Map<string, string>();
    return {
        getIsolateId: vi.fn(async (): Promise<string> => client.isolateId),
        getRootLibId: vi.fn(async (isolateId: string): Promise<string> => {
            const cached = rootLibCache.get(isolateId);
            if (cached) return cached;
            const iso = await call<IsolateInfo>('getIsolate', { isolateId });
            const id = iso.rootLib?.id;
            if (!id) throw new VmServiceError('getIsolate', -32000, 'missing rootLib.id');
            rootLibCache.set(isolateId, id);
            return id;
        }),
        call,
    };
}

/** Narrowing helper: read a call by index assuming index-access correctness. */
function callAt(client: FakeClient, index: number): { method: string; params?: unknown } {
    const entry = client.calls[index];
    if (!entry) throw new Error(`expected call at index ${index}`);
    return entry;
}

describe('get_widget_tree tool', () => {
    let client: FakeClient;
    let ctx: ToolContext;

    beforeEach(() => {
        client = fakeClient({
            'ext.flutter.inspector.getRootWidgetTree': {
                type: 'FlutterWidgetTree',
                description: 'WidgetsApp',
                children: [],
            },
        });
        ctx = context(client);
    });

    it('declares the right MCP tool metadata', () => {
        expect(getWidgetTreeTool.name).toBe('get_widget_tree');
        expect(getWidgetTreeTool.description).toBeTruthy();
        expect(getWidgetTreeTool.inputSchema).toBeDefined();
    });

    it('calls ext.flutter.inspector.getRootWidgetTree with isolateId + group params', async () => {
        await getWidgetTreeTool.handler(ctx, {});
        expect(client.calls).toHaveLength(1);
        const { method, params } = callAt(client, 0);
        expect(method).toBe('ext.flutter.inspector.getRootWidgetTree');
        expect(params).toMatchObject({
            isolateId: client.isolateId,
            groupName: 'agent',
            isSummaryTree: 'false',
            withPreviews: 'false',
        });
    });

    it('forwards the isSummaryTree option as a string', async () => {
        await getWidgetTreeTool.handler(ctx, { isSummaryTree: true });
        expect(callAt(client, 0).params).toMatchObject({ isSummaryTree: 'true' });
    });

    it('returns the response as MCP text content with serialized JSON', async () => {
        const result = await getWidgetTreeTool.handler(ctx, {});
        expect(result.content).toHaveLength(1);
        const first = result.content[0]!;
        expect(first.type).toBe('text');
        expect(JSON.parse(first.text)).toMatchObject({
            type: 'FlutterWidgetTree',
            description: 'WidgetsApp',
        });
    });

    it('translates VmServiceError into McpError', async () => {
        client.canned.clear();
        await expect(getWidgetTreeTool.handler(ctx, {})).rejects.toBeInstanceOf(McpError);
        await expect(getWidgetTreeTool.handler(ctx, {})).rejects.toMatchObject({ code: -32000 });
    });
});

describe('evaluate_dart tool', () => {
    let client: FakeClient;
    let ctx: ToolContext;

    beforeEach(() => {
        client = fakeClient({
            getIsolate: {
                type: 'Isolate',
                id: 'isolates/abc',
                rootLib: { type: '@Library', id: 'isolates/abc/libraries/9' },
            },
            evaluate: {
                type: '@Instance',
                kind: 'Int',
                valueAsString: '2',
            },
        });
        ctx = context(client);
    });

    it('declares the right MCP tool metadata', () => {
        expect(evaluateDartTool.name).toBe('evaluate_dart');
        expect(evaluateDartTool.description).toBeTruthy();
    });

    it('rejects empty expressions via zod validation', async () => {
        // Validation lives in the VALIDATING_HANDLERS wrapper; the raw
        // tool.handler accepts already-validated input.
        const validatingHandler = VALIDATING_HANDLERS.get('evaluate_dart');
        if (!validatingHandler) throw new Error('evaluate_dart validating handler missing');
        await expect(validatingHandler(ctx, { expression: '' })).rejects.toBeInstanceOf(McpError);
    });

    it('resolves rootLib once via getIsolate then calls evaluate with that targetId', async () => {
        await evaluateDartTool.handler(ctx, { expression: '1 + 1' });
        // First call must be getIsolate, second evaluate.
        const first = callAt(client, 0);
        const second = callAt(client, 1);
        expect(first.method).toBe('getIsolate');
        expect(first.params).toMatchObject({ isolateId: client.isolateId });
        expect(second.method).toBe('evaluate');
        expect(second.params).toMatchObject({
            isolateId: client.isolateId,
            targetId: client.rootLibId,
            expression: '1 + 1',
        });
    });

    it('caches the rootLib id across subsequent evaluate_dart calls', async () => {
        await evaluateDartTool.handler(ctx, { expression: '1' });
        await evaluateDartTool.handler(ctx, { expression: '2' });
        const isolateCalls = client.calls.filter((c) => c.method === 'getIsolate');
        expect(isolateCalls).toHaveLength(1);
    });

    it('returns evaluate response as MCP text content', async () => {
        const result = await evaluateDartTool.handler(ctx, { expression: '1 + 1' });
        const first = result.content[0]!;
        expect(first.type).toBe('text');
        const parsed = JSON.parse(first.text) as { valueAsString: string; kind: string };
        expect(parsed).toMatchObject({ valueAsString: '2', kind: 'Int' });
    });
});

describe('get_routes tool', () => {
    let client: FakeClient;
    let ctx: ToolContext;

    beforeEach(() => {
        client = fakeClient({
            'ext.aitest.getRoutes': {
                type: '_extensionType',
                location: '/dashboard',
                title: 'Dashboard',
            },
        });
        ctx = context(client);
    });

    it('declares the right MCP tool metadata', () => {
        expect(getRoutesTool.name).toBe('get_routes');
        expect(getRoutesTool.description).toBeTruthy();
    });

    it('calls ext.aitest.getRoutes with the isolate id', async () => {
        await getRoutesTool.handler(ctx, {});
        expect(client.calls).toHaveLength(1);
        const first = callAt(client, 0);
        expect(first.method).toBe('ext.aitest.getRoutes');
        expect(first.params).toMatchObject({ isolateId: client.isolateId });
    });

    it('returns the routes payload as MCP text content', async () => {
        const result = await getRoutesTool.handler(ctx, {});
        const first = result.content[0]!;
        const parsed = JSON.parse(first.text) as { location: string; title: string };
        expect(parsed.location).toBe('/dashboard');
        expect(parsed.title).toBe('Dashboard');
    });
});
