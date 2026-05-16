/**
 * Package entry-point for the ai-test MCP server.
 *
 * V3 split the previous single-file boot into three concerns:
 *
 *   - `src/server.ts` — `createServer()` factory + lazy VM client.
 *   - `src/cli.ts` — stdio glue that boots `createServer()` for the
 *      `ai-test-mcp` binary.
 *   - `src/index.ts` (this file) — programmatic re-export of the factory for
 *      library consumers and tests.
 *
 * The factory is exported by name (`createServer`) and as the default export
 * so callers can pick whichever ergonomics they prefer.
 */
export { createServer, lazyVmClient } from './server.js';
export type { LazyVmClient } from './server.js';
