import { z } from 'zod';
import { McpError, ErrorCode } from '@modelcontextprotocol/sdk/types.js';
import { VmServiceError } from '../vm_service_client.js';
import type { ToolDefinition, ToolContext } from './index.js';
import type { EvaluateResult, ToolResult } from '../types.js';

const inputSchema = z.object({
    expression: z
        .string()
        .min(1, 'expression must be a non-empty Dart source fragment')
        .describe('Dart expression to evaluate inside the running app, e.g. "1 + 1".'),
});

type Input = z.infer<typeof inputSchema>;

/**
 * MCP tool: `evaluate_dart`.
 *
 * Runs an arbitrary Dart expression in the running app via the VM Service
 * `evaluate` RPC, scoped to the app's root library (`main.dart`) so symbols
 * like `Magic.find<T>()`, `MagicRoute.currentLocation`, and `Auth.user()` resolve
 * naturally.
 */
export const evaluateDartTool: ToolDefinition<Input> = {
    name: 'evaluate_dart',
    description:
        'Run an arbitrary Dart expression in the running app, evaluated against the app entry library scope (main.dart). Examples: "Magic.find<MonitorController>().rxState.value", "MagicRoute.currentLocation", "Auth.user()?.email". Use for state inspection beyond the widget tree.',
    inputSchema,
    jsonSchema: {
        type: 'object',
        properties: {
            expression: {
                type: 'string',
                description:
                    'Dart expression to evaluate inside the running app, e.g. "1 + 1".',
                minLength: 1,
            },
        },
        required: ['expression'],
    },
    handler: async (ctx: ToolContext, args: Input): Promise<ToolResult> => {
        try {
            const isolateId = await ctx.getIsolateId();
            const targetId = await ctx.getRootLibId(isolateId);
            const result = await ctx.call<EvaluateResult>('evaluate', {
                isolateId,
                targetId,
                expression: args.expression,
            });
            return {
                content: [{ type: 'text', text: JSON.stringify(result) }],
            };
        } catch (err) {
            if (err instanceof McpError) throw err;
            if (err instanceof VmServiceError) {
                throw new McpError(
                    err.code === -32000 ? ErrorCode.ConnectionClosed : ErrorCode.InternalError,
                    `evaluate_dart: ${err.message}`,
                );
            }
            throw err;
        }
    },
};
