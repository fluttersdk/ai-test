/**
 * Shared TypeScript types for the ai-test MCP server.
 *
 * These types model the Dart VM Service Protocol 4.22 response shapes the server
 * actually consumes. They are intentionally narrow: the VM Service emits richer
 * payloads, but only the fields below are read by the MCP tools.
 */

/**
 * Subset of the VM Service `getVM` response. Used by `getMainIsolateId()`.
 *
 * @see https://github.com/dart-lang/sdk/blob/main/runtime/vm/service/service.md#vm
 */
export interface VmInfo {
    type: string;
    isolates: ReadonlyArray<{
        type: string;
        id: string;
        name?: string;
    }>;
}

/**
 * Subset of the VM Service `getIsolate` response. Used by `evaluate_dart` to
 * resolve the isolate's root library before issuing an `evaluate` RPC.
 *
 * @see https://github.com/dart-lang/sdk/blob/main/runtime/vm/service/service.md#isolate
 */
export interface IsolateInfo {
    type: string;
    id: string;
    rootLib: {
        type: string;
        id: string;
    };
}

/**
 * Subset of the VM Service `evaluate` RPC `@Instance` response.
 *
 * @see https://github.com/dart-lang/sdk/blob/main/runtime/vm/service/service.md#instance
 */
export interface EvaluateResult {
    type: string;
    kind?: string;
    valueAsString?: string;
    [extra: string]: unknown;
}

/**
 * Subset of the Flutter Inspector `getRootWidgetTree` response. The full tree
 * carries an open recursive `children` list plus widget-specific properties; we
 * forward the entire payload to the agent without trimming.
 */
export interface WidgetTreeNode {
    description?: string;
    type?: string;
    children?: ReadonlyArray<WidgetTreeNode>;
    [extra: string]: unknown;
}

/**
 * Shape returned by the Dart-side `ext.aitest.getRoutes` extension (Step 4).
 */
export interface RoutesResult {
    location: string;
    title: string;
}

/**
 * MCP tool result shape — `text` content with serialized JSON payload.
 *
 * Note on `type: 'text'`: the MCP `CallToolResult` content variants are `text`,
 * `image`, `audio`, and `resource`. There is no `json` variant in the spec; the
 * convention for structured returns is to JSON-stringify into a `text` block so
 * agents can re-parse on their side.
 */
export interface ToolResult {
    content: ReadonlyArray<{ type: 'text'; text: string }>;
}
