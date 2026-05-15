import { z } from 'zod';
import { McpError, ErrorCode } from '@modelcontextprotocol/sdk/types.js';
import { VmServiceError } from '../vm_service_client.js';
import type { ToolDefinition, ToolContext } from './index.js';
import type { ToolResult, WidgetTreeNode } from '../types.js';

const inputSchema = z.object({
    isSummaryTree: z
        .boolean()
        .optional()
        .describe(
            'When true, return the summary widget tree (skips diagnostic-only nodes). Defaults to false.',
        ),
});

type Input = z.infer<typeof inputSchema>;

/**
 * MCP tool: `get_widget_tree`.
 *
 * Calls the Flutter Inspector RPC `ext.flutter.inspector.getRootWidgetTree`
 * (registered automatically by the Flutter framework in debug builds, see
 * Flutter DevTools issue #8150) and returns the entire widget tree as a
 * serialized JSON blob inside an MCP `text` content block.
 *
 * The agent uses this tool to discover what is on screen by widget type, key,
 * properties, and bounding boxes — the primary surface for "where is the X
 * button" style queries.
 */
export const getWidgetTreeTool: ToolDefinition<Input> = {
    name: 'get_widget_tree',
    description:
        'Get the full Flutter widget tree as JSON. Use this to discover what is on the screen by widget type, key, properties, and bounding boxes.',
    inputSchema,
    jsonSchema: {
        type: 'object',
        properties: {
            isSummaryTree: {
                type: 'boolean',
                description:
                    'When true, return the summary widget tree (skips diagnostic-only nodes). Defaults to false.',
            },
        },
    },
    handler: async (ctx: ToolContext, args: Input): Promise<ToolResult> => {
        try {
            const isolateId = await ctx.getIsolateId();
            const result = await ctx.call<WidgetTreeNode>(
                'ext.flutter.inspector.getRootWidgetTree',
                {
                    isolateId,
                    groupName: 'agent',
                    isSummaryTree: String(args.isSummaryTree ?? false),
                    withPreviews: 'false',
                },
            );
            return {
                content: [{ type: 'text', text: JSON.stringify(result) }],
            };
        } catch (err) {
            if (err instanceof VmServiceError) {
                throw new McpError(
                    err.code === -32000 ? ErrorCode.ConnectionClosed : ErrorCode.InternalError,
                    `get_widget_tree: ${err.message}`,
                );
            }
            throw err;
        }
    },
};
