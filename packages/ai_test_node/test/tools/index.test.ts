import { describe, expect, it } from 'vitest';

import { makeToolContext } from '../../src/tools/index.js';
import type { VmServiceClient } from '../../src/vm_service_client.js';

/**
 * Build a fake `VmServiceClient` whose `getMainIsolateId` returns scripted
 * values per call. Mirrors what the production lazy wrapper does after a
 * device-target switch (state.json's vmServiceUri changes → underlying client
 * is rebuilt → next getMainIsolateId reports the new isolate).
 */
function buildFakeVmClient(
    isolateIds: ReadonlyArray<string>,
): Pick<VmServiceClient, 'getMainIsolateId' | 'getRootLibId' | 'call'> {
    let cursor = 0;
    return {
        async getMainIsolateId(): Promise<string> {
            const next = isolateIds[Math.min(cursor, isolateIds.length - 1)] ?? '';
            cursor++;
            return next;
        },
        async getRootLibId(_isolateId: string): Promise<string> {
            return 'libraries/rootlib';
        },
        async call<T>(_method: string, _params?: object): Promise<T> {
            throw new Error('not used by this test');
        },
    };
}

describe('makeToolContext.getIsolateId', () => {
    it('reflects the current vmClient isolate when it changes between calls',
        async () => {
            // Simulates: chrome session → isolates/chrome, then macos session
            // → isolates/macos (after the lazy client URI-switch rebuild in
            // server.ts:ensureConnected).
            const vmClient = buildFakeVmClient([
                'isolates/chrome',
                'isolates/macos',
            ]);
            const ctx = makeToolContext(vmClient);

            const first = await ctx.getIsolateId();
            const second = await ctx.getIsolateId();

            // The legacy implementation cached the first id forever, so the
            // second call returned `isolates/chrome` even after the app
            // restarted on a new device — every downstream ext.aitest.* call
            // then failed with VM Service "Invalid params" because the stale
            // isolate id no longer existed on the new VM.
            expect(first).toBe('isolates/chrome');
            expect(second).toBe('isolates/macos');
        });

    it('always delegates to vmClient — no closure-level cache shadowing it',
        async () => {
            const vmClient = buildFakeVmClient([
                'isolates/a',
                'isolates/b',
                'isolates/c',
            ]);
            const ctx = makeToolContext(vmClient);

            expect(await ctx.getIsolateId()).toBe('isolates/a');
            expect(await ctx.getIsolateId()).toBe('isolates/b');
            expect(await ctx.getIsolateId()).toBe('isolates/c');
        });
});
