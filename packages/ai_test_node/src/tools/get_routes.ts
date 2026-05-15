import { z } from 'zod';
import { McpError, ErrorCode } from '@modelcontextprotocol/sdk/types.js';
import { VmServiceError } from '../vm_service_client.js';
import type { ToolDefinition, ToolContext } from './index.js';
import type { RoutesResult, ToolResult } from '../types.js';

const inputSchema = z.object({}).strict();

type Input = z.infer<typeof inputSchema>;

/**
 * MCP tool: `get_routes`.
 *
 * Calls the Dart-side `ext.aitest.getRoutes` custom extension (registered by the
 * `ai_test_flutter` plugin in debug mode, see Step 4 of the V2 plan). Returns
 * the current GoRouter location and the page title.
 */
export const getRoutesTool: ToolDefinition<Input> = {
    name: 'get_routes',
    description:
        'Get the current GoRouter location + page title. Use to verify navigation state after a route change.',
    inputSchema,
    jsonSchema: {
        type: 'object',
        properties: {},
        additionalProperties: false,
    },
    handler: async (ctx: ToolContext, _args: Input): Promise<ToolResult> => {
        try {
            const isolateId = await ctx.getIsolateId();
            const result = await ctx.call<RoutesResult>('ext.aitest.getRoutes', {
                isolateId,
            });
            return {
                content: [{ type: 'text', text: JSON.stringify(result) }],
            };
        } catch (err) {
            if (err instanceof VmServiceError) {
                throw new McpError(
                    err.code === -32000 ? ErrorCode.ConnectionClosed : ErrorCode.InternalError,
                    `get_routes: ${err.message}`,
                );
            }
            throw err;
        }
    },
};
