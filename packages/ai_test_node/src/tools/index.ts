import { z } from 'zod';
import {
    CallToolRequestSchema,
    ListToolsRequestSchema,
    McpError,
    ErrorCode,
} from '@modelcontextprotocol/sdk/types.js';
import type { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { VmServiceClient } from '../vm_service_client.js';
import type { ToolResult } from '../types.js';
import { evaluateDartTool } from './evaluate_dart.js';
import { getRoutesTool } from './get_routes.js';
import { getWidgetTreeTool } from './get_widget_tree.js';

/**
 * Context surface a tool handler receives. The handler does not own the VM
 * Service connection; it borrows it from the MCP server's lazy singleton via
 * the two callbacks below. This indirection keeps tools unit-testable: tests
 * supply fake `call` + `getIsolateId` callbacks without spinning up a
 * WebSocket.
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
     * Send a JSON-RPC request to the VM Service.
     */
    call<T = unknown>(method: string, params?: object): Promise<T>;
}

/**
 * Definition of a single MCP tool. The `handler` runs `inputSchema` parsing
 * internally so transport-level invocations and direct unit-test calls share
 * the same validation path.
 */
export interface ToolDefinition<TInput> {
    readonly name: string;
    readonly description: string;
    readonly inputSchema: z.ZodType<TInput>;
    readonly jsonSchema: Record<string, unknown>;
    handler(ctx: ToolContext, args: unknown): Promise<ToolResult>;
}

export { evaluateDartTool, getRoutesTool, getWidgetTreeTool };

/**
 * Validate input against the tool's zod schema, translating any parse error
 * into the MCP `InvalidParams` error envelope so the client sees a typed
 * protocol error rather than an unhandled exception.
 */
function parseInput<TInput>(tool: ToolDefinition<TInput>, args: unknown): TInput {
    const result = tool.inputSchema.safeParse(args ?? {});
    if (!result.success) {
        throw new McpError(
            ErrorCode.InvalidParams,
            `${tool.name}: ${result.error.issues.map((i) => i.message).join('; ')}`,
        );
    }
    return result.data;
}

/**
 * Wrap a tool definition's underlying handler so external callers (the MCP
 * server, the unit tests) always go through input validation first.
 *
 * The handlers exported by `get_widget_tree.ts`, `evaluate_dart.ts`,
 * `get_routes.ts` accept already-validated input. This barrel re-exposes them
 * with a validating wrapper so callers don't have to parse manually.
 */
function makeValidatingHandler<TInput>(
    tool: { handler(ctx: ToolContext, args: TInput): Promise<ToolResult> },
    schema: z.ZodType<TInput>,
    name: string,
): (ctx: ToolContext, args: unknown) => Promise<ToolResult> {
    return async (ctx, args) => {
        const result = schema.safeParse(args ?? {});
        if (!result.success) {
            throw new McpError(
                ErrorCode.InvalidParams,
                `${name}: ${result.error.issues.map((i) => i.message).join('; ')}`,
            );
        }
        return tool.handler(ctx, result.data);
    };
}

/**
 * All MCP tools the server exposes, in registration order. The handler stored
 * on each `ToolDefinition` accepts already-validated input; the validating
 * wrappers in `VALIDATING_HANDLERS` below sit on top for transport-level callers
 * (the MCP server) and direct unit-test invocations.
 */
export const ALL_TOOLS: ReadonlyArray<ToolDefinition<unknown>> = [
    getWidgetTreeTool as ToolDefinition<unknown>,
    evaluateDartTool as ToolDefinition<unknown>,
    getRoutesTool as ToolDefinition<unknown>,
];

/**
 * Validating-handler lookup keyed by tool name. Built once at module load by
 * wrapping each tool's raw handler with `makeValidatingHandler`. This keeps the
 * `ToolDefinition.handler` slot immutable (no readonly-cast tricks) while still
 * giving callers a one-stop validating dispatch.
 */
export const VALIDATING_HANDLERS: ReadonlyMap<
    string,
    (ctx: ToolContext, args: unknown) => Promise<ToolResult>
> = new Map([
    [
        getWidgetTreeTool.name,
        makeValidatingHandler(
            getWidgetTreeTool,
            getWidgetTreeTool.inputSchema as z.ZodType<unknown>,
            getWidgetTreeTool.name,
        ),
    ],
    [
        evaluateDartTool.name,
        makeValidatingHandler(
            evaluateDartTool,
            evaluateDartTool.inputSchema as z.ZodType<unknown>,
            evaluateDartTool.name,
        ),
    ],
    [
        getRoutesTool.name,
        makeValidatingHandler(
            getRoutesTool,
            getRoutesTool.inputSchema as z.ZodType<unknown>,
            getRoutesTool.name,
        ),
    ],
]);

// `parseInput` is exported in shape only for callers that want to validate
// outside the handler path. Reference it once so dead-code elimination keeps it.
void parseInput;

/**
 * Register the MCP `tools/list` and `tools/call` handlers on the given Server
 * instance. The `vmClient` provides the live VM Service connection; tools
 * borrow it through a thin `ToolContext` adapter that caches the main isolate
 * id across calls.
 */
export function registerAll(server: Server, vmClient: VmServiceClient): void {
    let cachedIsolateId: string | null = null;

    const ctx: ToolContext = {
        async getIsolateId() {
            if (cachedIsolateId) return cachedIsolateId;
            cachedIsolateId = await vmClient.getMainIsolateId();
            return cachedIsolateId;
        },
        getRootLibId(isolateId: string) {
            return vmClient.getRootLibId(isolateId);
        },
        call<T>(method: string, params?: object) {
            return vmClient.call<T>(method, params ?? {});
        },
    };

    server.setRequestHandler(ListToolsRequestSchema, async () => ({
        tools: ALL_TOOLS.map((tool) => ({
            name: tool.name,
            description: tool.description,
            inputSchema: tool.jsonSchema as {
                type: 'object';
                properties?: Record<string, unknown>;
                required?: string[];
            },
        })),
    }));

    server.setRequestHandler(CallToolRequestSchema, async (request) => {
        const { name, arguments: rawArgs } = request.params;
        const handler = VALIDATING_HANDLERS.get(name);
        if (!handler) {
            throw new McpError(ErrorCode.MethodNotFound, `Unknown tool: ${name}`);
        }
        const result = await handler(ctx, rawArgs ?? {});
        return {
            content: result.content.map((c) => ({ type: c.type, text: c.text })),
        };
    });
}
