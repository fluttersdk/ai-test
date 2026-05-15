import { z } from 'zod';
import { McpError, ErrorCode } from '@modelcontextprotocol/sdk/types.js';
import { VmServiceError } from '../vm_service_client.js';
import type { ToolDefinition, ToolContext } from './index.js';
import type { EvaluateResult, IsolateInfo, ToolResult } from '../types.js';

const inputSchema = z.object({
    expression: z
        .string()
        .min(1, 'expression must be a non-empty Dart source fragment')
        .describe('Dart expression to evaluate inside the running app, e.g. "1 + 1".'),
});

type Input = z.infer<typeof inputSchema>;

/**
 * Per-session cache of the resolved root library id for the current isolate.
 *
 * The Dart VM `evaluate` RPC needs a `targetId` (library, class, or instance)
 * whose scope hosts the imports the expression should resolve against. The
 * Flutter DevTools convention is to evaluate against the app's entry library,
 * `package:<app>/main.dart`, which transitively imports the controllers and
 * the Magic facade barrel. We resolve it once per isolate via `getIsolate` and
 * cache the result.
 *
 * Keyed by isolate id so a reconnect against a fresh isolate invalidates the
 * cache naturally.
 */
const rootLibCache = new Map<string, string>();

async function resolveRootLibId(ctx: ToolContext, isolateId: string): Promise<string> {
    const cached = rootLibCache.get(isolateId);
    if (cached) return cached;
    const isolate = await ctx.call<IsolateInfo>('getIsolate', { isolateId });
    const rootLibId = isolate.rootLib?.id;
    if (!rootLibId) {
        throw new McpError(
            ErrorCode.InternalError,
            'evaluate_dart: isolate response missing rootLib.id',
        );
    }
    rootLibCache.set(isolateId, rootLibId);
    return rootLibId;
}

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
            const targetId = await resolveRootLibId(ctx, isolateId);
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

/**
 * Test-only helper to reset the in-process root-library cache between cases.
 * Not exported through the public barrel; imported via direct path in tests.
 */
export function _clearRootLibCacheForTests(): void {
    rootLibCache.clear();
}
