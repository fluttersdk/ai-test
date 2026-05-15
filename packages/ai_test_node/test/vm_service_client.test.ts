import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { AddressInfo } from 'node:net';
import { WebSocketServer, WebSocket as NodeWs } from 'ws';
import { VmServiceClient, VmServiceError } from '../src/vm_service_client.js';

/**
 * Spins up an in-process WebSocket server that scripts canned JSON-RPC 2.0
 * responses keyed by inbound request method. Mimics a Dart VM Service endpoint.
 */
interface FakeVmServer {
    readonly uri: string;
    readonly server: WebSocketServer;
    readonly sockets: Set<NodeWs>;
}

type Responder = (request: { id: number; method: string; params?: unknown }) => unknown;

function startFakeVmServer(responder: Responder): Promise<FakeVmServer> {
    return new Promise((resolve, reject) => {
        const sockets = new Set<NodeWs>();
        const server = new WebSocketServer({ port: 0, host: '127.0.0.1' }, () => {
            const address = server.address() as AddressInfo;
            resolve({
                server,
                sockets,
                uri: `ws://127.0.0.1:${address.port}/ws`,
            });
        });
        server.on('error', reject);
        server.on('connection', (socket) => {
            sockets.add(socket);
            socket.on('message', (raw) => {
                const incoming = JSON.parse(raw.toString()) as {
                    id: number;
                    method: string;
                    params?: unknown;
                };
                let payload;
                try {
                    payload = responder(incoming);
                } catch (err) {
                    socket.send(
                        JSON.stringify({
                            jsonrpc: '2.0',
                            id: incoming.id,
                            error: {
                                code: -32000,
                                message: err instanceof Error ? err.message : String(err),
                            },
                        }),
                    );
                    return;
                }
                socket.send(
                    JSON.stringify({
                        jsonrpc: '2.0',
                        id: incoming.id,
                        result: payload,
                    }),
                );
            });
            socket.on('close', () => sockets.delete(socket));
        });
    });
}

async function stopFakeVmServer(fake: FakeVmServer): Promise<void> {
    for (const socket of fake.sockets) {
        socket.terminate();
    }
    await new Promise<void>((resolve) => fake.server.close(() => resolve()));
}

describe('VmServiceClient', () => {
    let fake: FakeVmServer;
    let client: VmServiceClient | null;

    beforeEach(() => {
        client = null;
    });

    afterEach(async () => {
        if (client) {
            await client.disconnect();
            client = null;
        }
        if (fake) {
            await stopFakeVmServer(fake);
        }
    });

    it('connects to the VM Service over WebSocket', async () => {
        fake = await startFakeVmServer(() => ({}));
        client = new VmServiceClient(fake.uri);
        await client.connect();
        expect(client.isConnected).toBe(true);
    });

    it('routes call() to the matching JSON-RPC response by id', async () => {
        fake = await startFakeVmServer((req) => {
            if (req.method === 'getVersion') {
                return { type: 'Version', major: 4, minor: 22 };
            }
            throw new Error(`Unexpected method ${req.method}`);
        });
        client = new VmServiceClient(fake.uri);
        await client.connect();
        const result = await client.call<{ major: number; minor: number }>('getVersion');
        expect(result.major).toBe(4);
        expect(result.minor).toBe(22);
    });

    it('correlates concurrent calls by id', async () => {
        fake = await startFakeVmServer((req) => {
            if (req.method === 'a') return { tag: 'a' };
            if (req.method === 'b') return { tag: 'b' };
            throw new Error('unknown');
        });
        client = new VmServiceClient(fake.uri);
        await client.connect();
        const [a, b] = await Promise.all([
            client.call<{ tag: string }>('a'),
            client.call<{ tag: string }>('b'),
        ]);
        expect(a.tag).toBe('a');
        expect(b.tag).toBe('b');
    });

    it('throws VmServiceError when the server returns a JSON-RPC error', async () => {
        fake = await startFakeVmServer((req) => {
            throw new Error(`bad method: ${req.method}`);
        });
        client = new VmServiceClient(fake.uri);
        await client.connect();
        await expect(client.call('badMethod')).rejects.toBeInstanceOf(VmServiceError);
        await expect(client.call('badMethod')).rejects.toMatchObject({
            code: -32000,
            method: 'badMethod',
        });
    });

    it('returns the first isolate id from getMainIsolateId()', async () => {
        fake = await startFakeVmServer((req) => {
            if (req.method === 'getVM') {
                return {
                    type: 'VM',
                    isolates: [
                        { type: '@Isolate', id: 'isolates/12345', name: 'main' },
                        { type: '@Isolate', id: 'isolates/67890', name: 'worker' },
                    ],
                };
            }
            throw new Error(`unexpected method ${req.method}`);
        });
        client = new VmServiceClient(fake.uri);
        await client.connect();
        const id = await client.getMainIsolateId();
        expect(id).toBe('isolates/12345');
    });

    it('throws VmServiceError if getVM returns no isolates', async () => {
        fake = await startFakeVmServer((req) => {
            if (req.method === 'getVM') return { type: 'VM', isolates: [] };
            throw new Error('unexpected');
        });
        client = new VmServiceClient(fake.uri);
        await client.connect();
        await expect(client.getMainIsolateId()).rejects.toBeInstanceOf(VmServiceError);
    });

    it('rejects pending calls when the socket closes mid-flight', async () => {
        fake = await startFakeVmServer(() => ({}));
        client = new VmServiceClient(fake.uri);
        await client.connect();
        const pending = client.call('willNeverResolve');
        // Force close from server side without responding.
        for (const socket of fake.sockets) socket.terminate();
        await expect(pending).rejects.toBeInstanceOf(VmServiceError);
    });

    it('disconnect() closes the underlying WebSocket', async () => {
        fake = await startFakeVmServer(() => ({}));
        client = new VmServiceClient(fake.uri);
        await client.connect();
        await client.disconnect();
        expect(client.isConnected).toBe(false);
        client = null;
    });

    it('throws when call() is invoked before connect()', async () => {
        fake = await startFakeVmServer(() => ({}));
        client = new VmServiceClient(fake.uri);
        await expect(client.call('getVersion')).rejects.toBeInstanceOf(VmServiceError);
    });
});
