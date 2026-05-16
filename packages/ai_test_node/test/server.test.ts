import { describe, expect, it } from 'vitest';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { createServer } from '../src/server.js';

/**
 * Expected V3 MCP tool catalog after Oracle cull (19 entries).
 *
 * Step 18 ships 19 EMPTY tool slots; Wave 6 (Steps 19-22) fills the handlers.
 * The 4 culled tools (`flutter_inspect_state`, `flutter_inspect_form`,
 * `flutter_handle_dialog`, `flutter_hot_reload`) must NOT appear here.
 */
const EXPECTED_TOOL_NAMES: ReadonlyArray<string> = [
    // V2 carry-overs (renamed).
    'flutter_evaluate',
    'flutter_get_routes',
    // V3 navigation + lifecycle (Wave 6 Step 19).
    'flutter_navigate',
    'flutter_navigate_back',
    'flutter_close_app',
    'flutter_resize',
    // V3 interaction (Wave 6 Step 20).
    'flutter_tap',
    'flutter_type',
    'flutter_press_key',
    'flutter_hover',
    'flutter_drag',
    'flutter_select_option',
    'flutter_file_upload',
    // V3 snapshot + screenshot + wait (Wave 6 Step 21; flutter_evaluate listed above).
    'flutter_snapshot',
    'flutter_screenshot',
    'flutter_wait_for',
    // V3 network + mock (Wave 6 Step 22).
    'flutter_network_requests',
    'flutter_console_messages',
    'flutter_mock_http',
];

/**
 * Bring up `createServer()` connected to an in-process `Client` via a linked
 * pair of in-memory transports. The returned `cleanup` closes both sides.
 *
 * Using in-memory transport keeps the test hermetic: no WebSocket, no stdio,
 * no real VM Service connection. Real handlers that contact the VM Service
 * (all except `flutter_resize` and `flutter_file_upload`) will fail with a
 * connection error, which the tool wrappers return as `{ isError: true }`.
 */
async function bootInMemoryServer(): Promise<{
    client: Client;
    cleanup: () => Promise<void>;
}> {
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    const server = createServer();
    const client = new Client(
        {
            name: 'ai-test-server-test',
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

describe('createServer()', () => {
    it('exposes exactly 19 MCP tools matching the V3 catalog', async () => {
        const { client, cleanup } = await bootInMemoryServer();
        try {
            const { tools } = await client.listTools();
            const names = tools.map((t) => t.name).sort();
            expect(names).toEqual([...EXPECTED_TOOL_NAMES].sort());
            expect(tools).toHaveLength(19);
        } finally {
            await cleanup();
        }
    });

    it('declares a non-empty description for every tool slot', async () => {
        const { client, cleanup } = await bootInMemoryServer();
        try {
            const { tools } = await client.listTools();
            for (const tool of tools) {
                expect(tool.description, `description for ${tool.name}`).toBeTruthy();
            }
        } finally {
            await cleanup();
        }
    });

    it('never returns the NOT YET IMPLEMENTED sentinel — real Wave 6 handlers are wired', async () => {
        // Wave 6 real handlers are now wired. The stub sentinel
        // "NOT YET IMPLEMENTED" must not appear in any tool response:
        //
        // - Tools requiring VM Service access return a connection-error
        //   envelope (`isError: true`) because no Flutter app is running.
        // - `flutter_close_app` succeeds (disconnect is a no-op when the
        //   lazy client was never connected) and returns `{closed: true}`.
        // - `flutter_resize` returns `isError: true` (ALPHA stub).
        // - `flutter_file_upload` returns `isError: true` (V3.1 deferred).
        //
        // In all cases the "NOT YET IMPLEMENTED" text must be absent.
        const { client, cleanup } = await bootInMemoryServer();
        try {
            for (const name of EXPECTED_TOOL_NAMES) {
                const result = await client.callTool({
                    name,
                    // Supply extra fields so zod validation passes for tools
                    // with required args (flutter_navigate needs `route`,
                    // flutter_tap needs `ref`, flutter_resize needs
                    // `width` + `height`, etc.). Extra keys are ignored by
                    // tools that do not declare them in their inputSchema.
                    arguments: {
                        route: '/test',
                        ref: 'e1',
                        startRef: 'e1',
                        endRef: 'e2',
                        values: ['a'],
                        paths: ['/tmp/a.txt'],
                        key: 'Enter',
                        expression: 'true',
                        condition: 'true',
                        width: 1280,
                        height: 800,
                        pattern: '/api/*',
                        response: {},
                    },
                });
                const content = result.content as ReadonlyArray<{
                    type: string;
                    text?: string;
                }>;
                expect(content[0]?.type, `${name} content[0].type`).toBe('text');
                expect(
                    content[0]?.text,
                    `${name} must NOT return the stub sentinel`,
                ).not.toBe('NOT YET IMPLEMENTED');
            }
        } finally {
            await cleanup();
        }
    });
});
