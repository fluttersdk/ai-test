import { WebSocket } from 'ws';
import type { VmInfo, IsolateInfo } from './types.js';

/**
 * Typed JSON-RPC error raised by `VmServiceClient` whenever the VM Service
 * returns an `error` envelope, the socket closes with pending requests, or the
 * client is used in an invalid state. Carries the originating method name and
 * the JSON-RPC `code` so MCP tools can map to MCP error codes.
 */
export class VmServiceError extends Error {
    public readonly method: string;
    public readonly code: number;
    public readonly data: unknown;

    public constructor(method: string, code: number, message: string, data?: unknown) {
        super(message);
        this.name = 'VmServiceError';
        this.method = method;
        this.code = code;
        this.data = data;
    }
}

interface PendingCall {
    readonly method: string;
    resolve(value: unknown): void;
    reject(error: Error): void;
}

interface JsonRpcResponse {
    jsonrpc: '2.0';
    id: number;
    result?: unknown;
    error?: { code: number; message: string; data?: unknown };
}

/**
 * Minimal Dart VM Service Protocol 4.22 WebSocket client.
 *
 * Wraps the `ws` library to speak JSON-RPC 2.0 against a running Flutter Web app
 * launched with `--enable-vm-service`. The endpoint URI accepts both auth-codes-on
 * (`ws://host:port/<token>/ws`) and auth-codes-off (`ws://host:port/ws`) forms;
 * the caller is responsible for picking the right one based on operator policy.
 *
 * The client correlates requests and responses by an auto-incrementing `id`;
 * concurrent calls are safe. Any pending call is rejected with `VmServiceError`
 * if the socket closes mid-flight.
 */
export class VmServiceClient {
    private readonly _uri: string;
    private _socket: WebSocket | null = null;
    private _nextId = 1;
    private readonly _pending = new Map<number, PendingCall>();
    private readonly _rootLibCache = new Map<string, string>();

    public constructor(uri: string) {
        this._uri = uri;
    }

    /**
     * True once the WebSocket handshake has completed and the socket is open.
     */
    public get isConnected(): boolean {
        return this._socket !== null && this._socket.readyState === WebSocket.OPEN;
    }

    /**
     * Open the WebSocket connection. Resolves on the `open` event; rejects with
     * the underlying error on socket failure.
     */
    public connect(): Promise<void> {
        return new Promise((resolve, reject) => {
            const socket = new WebSocket(this._uri);

            const onError = (err: Error): void => {
                socket.removeListener('open', onOpen);
                reject(err);
            };

            const onOpen = (): void => {
                socket.removeListener('error', onError);
                this._socket = socket;
                socket.on('message', this._handleMessage);
                socket.on('close', this._handleClose);
                socket.on('error', this._handleError);
                resolve();
            };

            socket.once('open', onOpen);
            socket.once('error', onError);
        });
    }

    /**
     * Send a JSON-RPC 2.0 request and resolve with the `result` field.
     *
     * @throws {VmServiceError} when the server returns an `error` envelope, the
     *     client is not connected, or the socket closes before a response.
     */
    public call<T = unknown>(method: string, params: object = {}): Promise<T> {
        if (!this.isConnected || !this._socket) {
            return Promise.reject(
                new VmServiceError(method, -32000, 'VmServiceClient is not connected'),
            );
        }
        const id = this._nextId++;
        const payload = JSON.stringify({ jsonrpc: '2.0', id, method, params });
        return new Promise<T>((resolve, reject) => {
            this._pending.set(id, {
                method,
                resolve: (value) => resolve(value as T),
                reject,
            });
            this._socket!.send(payload, (err) => {
                if (err) {
                    this._pending.delete(id);
                    reject(new VmServiceError(method, -32000, err.message));
                }
            });
        });
    }

    /**
     * Resolve the id of the main (first) isolate exposed by the running VM.
     * Single-isolate Flutter Web apps will have exactly one entry; if the VM
     * exposes none, throws `VmServiceError`.
     */
    public async getMainIsolateId(): Promise<string> {
        const vm = await this.call<VmInfo>('getVM');
        const first = vm.isolates[0];
        if (!first) {
            throw new VmServiceError(
                'getVM',
                -32000,
                'VM Service reported no isolates; is the Flutter app fully booted?',
            );
        }
        return first.id;
    }

    /**
     * Resolve (and cache) the root library id for the given isolate.
     *
     * The Dart VM `evaluate` RPC needs a `targetId` whose scope hosts the
     * imports the expression should resolve against. The Flutter DevTools
     * convention is `package:<app>/main.dart`, the entry library that
     * transitively imports controllers + the Magic facade barrel.
     *
     * Cached per isolate id, so a reconnect against a fresh isolate
     * invalidates the cache naturally.
     */
    public async getRootLibId(isolateId: string): Promise<string> {
        const cached = this._rootLibCache.get(isolateId);
        if (cached) return cached;
        const isolate = await this.call<IsolateInfo>('getIsolate', { isolateId });
        const rootLibId = isolate.rootLib?.id;
        if (!rootLibId) {
            throw new VmServiceError(
                'getIsolate',
                -32000,
                'isolate response missing rootLib.id',
            );
        }
        this._rootLibCache.set(isolateId, rootLibId);
        return rootLibId;
    }

    /**
     * Test-only helper to reset the in-process root-library cache between cases.
     */
    public clearRootLibCacheForTests(): void {
        this._rootLibCache.clear();
    }

    /**
     * Close the WebSocket. Pending calls are rejected with `VmServiceError`.
     * Safe to call multiple times.
     */
    public disconnect(): Promise<void> {
        return new Promise((resolve) => {
            const socket = this._socket;
            if (!socket) {
                resolve();
                return;
            }
            this._rejectAllPending('VmServiceClient disconnected');
            this._socket = null;
            socket.removeAllListeners();
            socket.once('close', () => resolve());
            try {
                socket.close();
            } catch {
                // Already closed; close event will not fire — resolve eagerly.
                resolve();
            }
        });
    }

    private _handleMessage = (raw: Buffer | ArrayBuffer | Buffer[]): void => {
        let response: JsonRpcResponse;
        try {
            const text = Array.isArray(raw)
                ? Buffer.concat(raw).toString('utf-8')
                : Buffer.from(raw as Buffer).toString('utf-8');
            response = JSON.parse(text) as JsonRpcResponse;
        } catch {
            // Malformed payload — drop it; protocol does not allow id-less rejection.
            return;
        }
        if (typeof response.id !== 'number') return;
        const pending = this._pending.get(response.id);
        if (!pending) return;
        this._pending.delete(response.id);
        if (response.error) {
            pending.reject(
                new VmServiceError(
                    pending.method,
                    response.error.code,
                    response.error.message,
                    response.error.data,
                ),
            );
            return;
        }
        pending.resolve(response.result);
    };

    private _handleClose = (): void => {
        this._rejectAllPending('VmServiceClient WebSocket closed before response');
        this._socket = null;
    };

    private _handleError = (err: Error): void => {
        this._rejectAllPending(`VmServiceClient WebSocket error: ${err.message}`);
    };

    private _rejectAllPending(reason: string): void {
        for (const [id, pending] of this._pending) {
            pending.reject(new VmServiceError(pending.method, -32000, reason));
            this._pending.delete(id);
        }
    }
}
