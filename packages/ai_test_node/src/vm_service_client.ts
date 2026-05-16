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
 * VM Service Protocol `streamNotify` envelope received for all stream events
 * (Isolate, Service, Logging, Extension, etc.). Not a JSON-RPC response — no `id`.
 */
interface StreamNotifyEnvelope {
    jsonrpc: '2.0';
    method: 'streamNotify';
    params: {
        streamId: string;
        event: {
            type: string;
            kind: string;
            /** Bare unqualified service name (e.g. `ext.aitest.tap` or `hotRestart`). */
            service?: string;
            /** DDS-qualified full name (e.g. `s0.ext.aitest.tap` or `s1.hotRestart`). */
            method?: string;
        };
    };
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
 *
 * DDS namespace map: when Flutter runs with DDS (default `flutter run -d chrome`),
 * built-in VM services are registered with a namespace prefix (`s1.hotRestart`,
 * `s2.reloadSources`). Custom `developer.registerExtension` extensions stay bare
 * (`ext.aitest.*`) on Flutter 3.41.6+ (spike-verified). This map is populated via
 * `Service` stream `ServiceRegistered` events and rewrites outgoing calls
 * defensively in case a future Flutter version namespaces `ext.*` as well.
 */
export class VmServiceClient {
    private readonly _uri: string;
    private _socket: WebSocket | null = null;
    private _nextId = 1;
    private readonly _pending = new Map<number, PendingCall>();
    private readonly _rootLibCache = new Map<string, string>();

    /**
     * DDS namespace registry. Maps bare service names to their DDS-qualified
     * names: `'ext.aitest.tap' → 's0.ext.aitest.tap'` (or bare → bare when
     * DDS does not prefix the name, which is the case for `ext.*` today).
     * Cleared on every disconnect so reconnects start with a fresh table.
     */
    private readonly _serviceRegistry = new Map<string, string>();

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
     * Open the WebSocket connection and subscribe to the `Service` stream so
     * the DDS namespace registry is populated before any extension calls go out.
     *
     * Resolves once the socket is open and the `streamListen('Service')` RPC
     * has been sent (not awaited to completion — stream events may arrive before
     * the response). Rejects with the underlying error on socket failure.
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

                // Subscribe to the Service stream so kServiceRegistered events
                // populate _serviceRegistry before any ext.* call goes out.
                // Fire-and-forget: do not block resolve() on the response.
                this._subscribeToServiceStream();

                resolve();
            };

            socket.once('open', onOpen);
            socket.once('error', onError);
        });
    }

    /**
     * Send `streamListen('Service')` without awaiting the response. Called
     * immediately after the socket opens so the DDS namespace registry receives
     * `ServiceRegistered` events as early as possible.
     */
    private _subscribeToServiceStream(): void {
        if (!this._socket) return;
        const id = this._nextId++;
        const payload = JSON.stringify({
            jsonrpc: '2.0',
            id,
            method: 'streamListen',
            params: { streamId: 'Service' },
        });
        // Consume the response (success or 'already subscribed' error) silently.
        this._pending.set(id, {
            method: 'streamListen',
            resolve: () => undefined,
            reject: () => undefined,
        });
        this._socket.send(payload);
    }

    /**
     * Send a JSON-RPC 2.0 request and resolve with the `result` field.
     *
     * When the `Service` stream registry contains a DDS-qualified name for
     * `method`, the outgoing RPC is rewritten to that qualified name. This is
     * the defensive namespace-rewrite path: on Flutter 3.41.6+ only built-in
     * VM services (`hotRestart`, `reloadSources`) are namespaced, so custom
     * `ext.aitest.*` extensions go out bare by default.
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
        // Rewrite to the DDS-qualified name when the registry has an entry.
        const resolvedMethod = this._serviceRegistry.get(method) ?? method;
        const id = this._nextId++;
        const payload = JSON.stringify({ jsonrpc: '2.0', id, method: resolvedMethod, params });
        return new Promise<T>((resolve, reject) => {
            this._pending.set(id, {
                method: resolvedMethod,
                resolve: (value) => resolve(value as T),
                reject,
            });
            this._socket!.send(payload, (err) => {
                if (err) {
                    this._pending.delete(id);
                    reject(new VmServiceError(resolvedMethod, -32000, err.message));
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
     * The DDS namespace registry is cleared so a subsequent `connect()` starts
     * with a fresh table. Safe to call multiple times.
     */
    public disconnect(): Promise<void> {
        return new Promise((resolve) => {
            const socket = this._socket;
            if (!socket) {
                resolve();
                return;
            }
            this._rejectAllPending('VmServiceClient disconnected');
            // Clear the namespace registry before nulling the socket — the
            // _handleClose handler is removed by removeAllListeners() below,
            // so the clear must happen here explicitly on a clean disconnect.
            this._serviceRegistry.clear();
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
        let envelope: JsonRpcResponse | StreamNotifyEnvelope;
        try {
            const text = Array.isArray(raw)
                ? Buffer.concat(raw).toString('utf-8')
                : Buffer.from(raw as Buffer).toString('utf-8');
            envelope = JSON.parse(text) as JsonRpcResponse | StreamNotifyEnvelope;
        } catch {
            // Malformed payload — drop it; protocol does not allow id-less rejection.
            return;
        }

        // 1. Route stream notifications (no `id`; method === 'streamNotify').
        if ((envelope as StreamNotifyEnvelope).method === 'streamNotify') {
            this._handleStreamNotify(envelope as StreamNotifyEnvelope);
            return;
        }

        // 2. Route JSON-RPC responses (numeric `id`).
        const response = envelope as JsonRpcResponse;
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

    /**
     * Process a `streamNotify` envelope from the VM Service. Handles
     * `ServiceRegistered` events to populate the DDS namespace registry.
     *
     * @param envelope - The parsed `streamNotify` message from the server.
     */
    private _handleStreamNotify(envelope: StreamNotifyEnvelope): void {
        const { streamId, event } = envelope.params;
        if (streamId !== 'Service' || event.kind !== 'ServiceRegistered') return;

        const bareName = event.service ?? '';
        const fullName = event.method ?? '';

        // Only record when the server provided both names and they differ — the
        // bare name alone is the hot path (no rewrite needed when bareName === fullName).
        if (bareName && fullName && bareName !== fullName) {
            this._serviceRegistry.set(bareName, fullName);
        }
    }

    private _handleClose = (): void => {
        this._rejectAllPending('VmServiceClient WebSocket closed before response');
        // Clear the registry so a reconnect starts with a fresh namespace table.
        this._serviceRegistry.clear();
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
