import type { z } from 'zod';
import type { VmServiceClient } from '../vm_service_client.js';
import type { ToolResult } from '../types.js';

/**
 * Tool barrel for the ai-test MCP server.
 *
 * The V2 `Server.setRequestHandler` pattern (and its `ALL_TOOLS` / `VALIDATING_HANDLERS`
 * registry) is gone — `src/server.ts` now uses `McpServer.registerTool`, which
 * owns input validation and dispatch internally.
 *
 * Wave 6 (Steps 19-22) lands the live tool implementations in their own
 * modules (`navigation.ts`, `interaction.ts`, `snapshot.ts`, `network.ts`) and
 * Step 22b re-exports them through this barrel for `createServer()` to import
 * via a single aggregator call. Until then this file only exposes the shared
 * `ToolContext` / `ToolDefinition` types the Wave 6 wrappers will conform to.
 */

/**
 * Context surface a tool handler receives. The handler does not own the VM
 * Service connection; it borrows it from the MCP server's lazy singleton via
 * the four callbacks below. This indirection keeps tools unit-testable: tests
 * supply fake callbacks without spinning up a WebSocket.
 */
export interface ToolContext {
    /**
     * Resolve (and cache) the main isolate id for the running app.
     */
    getIsolateId(): Promise<string>;
    /**
     * Resolve (and cache) the root library id for the given isolate. Delegates
     * to `VmServiceClient.getRootLibId`, which owns the per-isolate cache.
     */
    getRootLibId(isolateId: string): Promise<string>;
    /**
     * Send a JSON-RPC request to the VM Service. The wrapped client routes
     * `ext.aitest.*` calls through DDS-aware namespace mapping (Step 17).
     */
    call<T = unknown>(method: string, params?: object): Promise<T>;
}

/**
 * Definition of a single MCP tool handler. Wave 6 modules export one of these
 * per tool; the Step 22b aggregator collects them and registers each with
 * `McpServer.registerTool` inside `createServer()`.
 *
 * The `handler` runs against already-validated input (the McpServer parses
 * `inputSchema` before dispatching). Tests that bypass the MCP transport can
 * call `inputSchema.parse(args)` themselves and invoke `handler` directly.
 */
export interface ToolDefinition<TInput> {
    readonly name: string;
    readonly description: string;
    readonly inputSchema: z.ZodType<TInput>;
    /**
     * Legacy JSON Schema mirror of `inputSchema`, retained as optional so the
     * V2 tool files (`evaluate_dart.ts`, `get_routes.ts`) keep compiling until
     * Step 21 rewrites them. The McpServer pattern derives JSON Schema from
     * the zod input directly — Wave 6 wrappers should NOT populate this field.
     */
    readonly jsonSchema?: Record<string, unknown>;
    handler(ctx: ToolContext, args: TInput): Promise<ToolResult>;
}

/**
 * Build a `ToolContext` backed by the live `VmServiceClient` (or any object
 * implementing the same surface, e.g. the `LazyVmClient` proxy from
 * `server.ts`). Always delegates `getIsolateId` to the live client; the lazy
 * wrapper in `server.ts` rebuilds the underlying client whenever state.json's
 * vmServiceUri changes (device-target switch: chrome → macos, hot-restart on
 * the same target, etc.), and a stale closure-level cache here would point
 * every downstream `ext.aitest.*` call at the dead isolate and produce VM
 * Service `Invalid params` errors.
 *
 * The underlying `getMainIsolateId` is a single local-WebSocket `getVM` RPC
 * (sub-millisecond on Flutter web, low milliseconds on USB/wireless mobile);
 * skipping the cache trades nothing meaningful for correctness across device
 * sessions. The lower `VmServiceClient` keeps its own per-isolate caches
 * (e.g. `getRootLibId`) that survive across calls within one VM session.
 */
export function makeToolContext(
    vmClient: Pick<VmServiceClient, 'getMainIsolateId' | 'getRootLibId' | 'call'>,
): ToolContext {
    return {
        getIsolateId(): Promise<string> {
            return vmClient.getMainIsolateId();
        },
        getRootLibId(isolateId: string): Promise<string> {
            return vmClient.getRootLibId(isolateId);
        },
        call<T = unknown>(method: string, params?: object): Promise<T> {
            return vmClient.call<T>(method, params ?? {});
        },
    };
}
