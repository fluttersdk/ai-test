#!/usr/bin/env -S npx tsx
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { createServer } from './server.js';

/**
 * Boot the ai-test MCP server over stdio and run until the host disconnects.
 *
 * `McpServer.connect()` resolves only when the transport closes, so this
 * function returns naturally at the end of the host session. Tool-level errors
 * are reported through the MCP `isError: true` envelope; only fatal transport
 * issues escape and exit with a non-zero status.
 *
 * MCP stdio is bidirectional JSON-RPC over stdin / stdout, so EVERY log line
 * MUST go to stderr — writing to stdout corrupts the protocol frame.
 */
export async function main(): Promise<void> {
    const server = createServer();
    const transport = new StdioServerTransport();
    await server.connect(transport);
}

// Direct-invocation guard: skipped when imported as a module (e.g. by tests).
const invokedDirectly =
    process.argv[1] !== undefined && import.meta.url === `file://${process.argv[1]}`;
if (invokedDirectly) {
    main().catch((err: unknown) => {
        // stderr only — stdout carries the JSON-RPC frame.
        console.error('[ai-test-mcp] fatal:', err);
        process.exit(1);
    });
}
