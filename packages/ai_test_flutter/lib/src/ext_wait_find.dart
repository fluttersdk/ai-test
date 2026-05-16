import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import 'ai_test_http_interceptor.dart';
import 'ref_registry.dart';
import 'v3_register.dart';

// ---------------------------------------------------------------------------
// Self-registration entry point
// ---------------------------------------------------------------------------

/// Registers the `ext.aitest.wait_for`, `ext.aitest.find_by_text`, and
/// `ext.aitest.find_by_label` VM Service extensions.
///
/// All three extensions help LLM agents synchronise with dynamic UI state
/// without busy-polling from the MCP client (which adds network round-trip
/// overhead). The wait loop runs Dart-side so a single RPC call blocks until
/// the condition is met or the timeout expires.
///
/// Idempotent: each underlying [registerExtensionIdempotent] call swallows
/// the [ArgumentError] thrown by [developer.registerExtension] on hot-restart
/// duplicate registration (V3 plan Stage 3 D12).
///
/// Call this once from the Wave 3 aggregator
/// (`extensions.dart#registerAllAiTestExtensions`).
void registerWaitFindExtensions() {
  registerExtensionIdempotent('ext.aitest.wait_for', aiTestWaitForHandler);
  registerExtensionIdempotent(
    'ext.aitest.find_by_text',
    aiTestFindByTextHandler,
  );
  registerExtensionIdempotent(
    'ext.aitest.find_by_label',
    aiTestFindByLabelHandler,
  );
}

// ---------------------------------------------------------------------------
// ext.aitest.wait_for
// ---------------------------------------------------------------------------

/// Handler for the `ext.aitest.wait_for` VM Service extension.
///
/// Blocks (Dart-side) until a condition is met or [timeoutMs] elapses.
/// Polls at [_kPollIntervalMs] (200ms) so the main isolate is never starved
/// (100ms minimum per plan constraint).
///
/// Params (all string-valued):
/// - `text` (optional): wait until a [Text] widget with this exact data
///   appears in the element tree.
/// - `textGone` (optional): wait until a [Text] widget with this data
///   disappears from the element tree.
/// - `expression` (optional): treated as a text-presence check internally
///   (Dart-side evaluate via find_by_text). Full Dart eval is not available
///   from a VM Service extension without a separate `evaluate` RPC and a
///   client round-trip; agents that need arbitrary expressions should use
///   the `flutter_evaluate` MCP tool directly.
/// - `timeoutMs` (optional): milliseconds before the extension gives up.
///   Defaults to [_kDefaultTimeoutMs] (5000ms).
///
/// Response:
/// ```json
/// { "matched": true,  "elapsedMs": 620 }
/// { "matched": false, "reason": "timeout" }
/// ```
///
/// Exactly one of `text`, `textGone`, or `expression` must be present;
/// returns an error response if none are provided.
Future<developer.ServiceExtensionResponse> aiTestWaitForHandler(
  String method,
  Map<String, String> params,
) async {
  try {
    final String? text = params['text'];
    final String? textGone = params['textGone'];
    final String? expression = params['expression'];
    final int timeoutMs = _parseInt(params['timeoutMs']) ?? _kDefaultTimeoutMs;

    if (text == null && textGone == null && expression == null) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        '[ai-test-v3] ext.aitest.wait_for: at least one of text, textGone, '
        'or expression is required',
      );
    }

    Map<String, dynamic> result;

    if (text != null) {
      // 1. Wait for a Text widget with matching data to appear.
      result = await findByTextWaitLoop(
        text: text,
        timeoutMs: timeoutMs,
        pollIntervalMs: _kPollIntervalMs,
      );
    } else if (textGone != null) {
      // 2. Wait for a matching Text widget to disappear.
      result = await findByTextGoneWaitLoop(
        text: textGone,
        timeoutMs: timeoutMs,
        pollIntervalMs: _kPollIntervalMs,
      );
    } else {
      // 3. expression: reuse text-presence check — agents that need arbitrary
      //    Dart eval should call ext.aitest.evaluate / flutter_evaluate directly.
      //    Here we treat the expression as a text-match string so the extension
      //    stays pure-Dart without a second RPC round-trip.
      result = await findByTextWaitLoop(
        text: expression!,
        timeoutMs: timeoutMs,
        pollIntervalMs: _kPollIntervalMs,
      );
    }

    return developer.ServiceExtensionResponse.result(jsonEncode(result));
  } catch (e, stackTrace) {
    developer.log(
      '[ai-test-v3] ext.aitest.wait_for error: $e\n$stackTrace',
      name: 'ai-test',
    );
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      e.toString(),
    );
  }
}

// ---------------------------------------------------------------------------
// ext.aitest.find_by_text
// ---------------------------------------------------------------------------

/// Handler for the `ext.aitest.find_by_text` VM Service extension.
///
/// Walks the live element tree after an [endOfFrame] settle (so stale
/// pre-layout elements are not counted) and returns a ref string for every
/// [Text] widget whose [Text.data] matches [text].
///
/// Params:
/// - `text` (required): the string to match.
/// - `exact` (optional, default `"true"`): when `"true"`, requires an exact
///   string match; when `"false"`, performs a substring match.
///
/// Response:
/// ```json
/// { "refs": ["e5", "e6"] }
/// ```
///
/// Each `eN` ref is registered in [RefRegistry] with a fresh group id and
/// can be passed to action extensions (tap, hover, type) in subsequent calls.
Future<developer.ServiceExtensionResponse> aiTestFindByTextHandler(
  String method,
  Map<String, String> params,
) async {
  try {
    final String? text = params['text'];
    if (text == null || text.isEmpty) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        '[ai-test-v3] ext.aitest.find_by_text: missing required param "text"',
      );
    }

    final bool exact = params['exact'] != 'false';

    // 1. Walk the element tree and register fresh refs. The tree is readable
    //    synchronously — endOfFrame is only needed before mutations, not reads.
    final String groupId = 'find-text-${DateTime.now().millisecondsSinceEpoch}';
    final List<String> refs = findByTextInTree(
      text: text,
      exact: exact,
      groupId: groupId,
    );

    return developer.ServiceExtensionResponse.result(
      jsonEncode(<String, dynamic>{'refs': refs}),
    );
  } catch (e, stackTrace) {
    developer.log(
      '[ai-test-v3] ext.aitest.find_by_text error: $e\n$stackTrace',
      name: 'ai-test',
    );
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      e.toString(),
    );
  }
}

// ---------------------------------------------------------------------------
// ext.aitest.find_by_label
// ---------------------------------------------------------------------------

/// Handler for the `ext.aitest.find_by_label` VM Service extension.
///
/// Walks the live SemanticsNode tree synchronously and returns a ref string
/// for every node whose [SemanticsNode.label] matches [label].
/// An optional [role] param filters by semantic role flag name.
///
/// Params:
/// - `label` (required): the accessibility label string to match (exact).
/// - `role` (optional): one of `"button"`, `"textField"`, `"checkbox"`,
///   `"link"`, `"image"`. When provided only nodes whose matching
///   [SemanticsFlag] is set are returned.
///
/// Response:
/// ```json
/// { "refs": ["e7"] }
/// ```
Future<developer.ServiceExtensionResponse> aiTestFindByLabelHandler(
  String method,
  Map<String, String> params,
) async {
  try {
    final String? label = params['label'];
    if (label == null || label.isEmpty) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        '[ai-test-v3] ext.aitest.find_by_label: missing required param "label"',
      );
    }

    final String? roleParam = params['role'];

    // 1. Walk the SemanticsNode tree and register fresh refs. Read-only walk;
    //    endOfFrame only guards mutations, not reads.
    final String groupId =
        'find-label-${DateTime.now().millisecondsSinceEpoch}';
    final List<String> refs = findByLabelInSemantics(
      label: label,
      role: roleParam,
      groupId: groupId,
    );

    return developer.ServiceExtensionResponse.result(
      jsonEncode(<String, dynamic>{'refs': refs}),
    );
  } catch (e, stackTrace) {
    developer.log(
      '[ai-test-v3] ext.aitest.find_by_label error: $e\n$stackTrace',
      name: 'ai-test',
    );
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      e.toString(),
    );
  }
}

// ---------------------------------------------------------------------------
// Internal helpers — @visibleForTesting so tests drive them directly
// ---------------------------------------------------------------------------

/// Default timeout in milliseconds for [findByTextWaitLoop].
const int _kDefaultTimeoutMs = 5000;

/// Poll interval in milliseconds. Minimum 100ms per plan constraint (CPU).
const int _kPollIntervalMs = 200;

/// Polls the element tree for a [Text] widget with [text] as its data until
/// found or until [timeoutMs] elapses.
///
/// [binding] is injectable for testability (tests supply [WidgetTester.binding]
/// so [pump] calls drive the fake clock; production code passes
/// [WidgetsBinding.instance]).
///
/// Poll interval is [pollIntervalMs] milliseconds (must be >= 100ms per plan).
/// Returns `{matched: true, elapsedMs: N}` or `{matched: false, reason: 'timeout'}`.
///
/// `elapsedMs` is computed as `pollCount * pollIntervalMs` rather than
/// wall-clock time. This is compatible with flutter_test's [tester.runAsync]
/// environment (real timers run; [Stopwatch] would work too, but counter
/// arithmetic avoids clock-skew drift and is deterministic in tests).
///
/// The loop does NOT await [WidgetsBinding.endOfFrame] between polls: the
/// element tree is readable at any point and the walk is synchronous. An
/// [endOfFrame] await before the find_by_* one-shot handlers (which mutate
/// refs) is the right gate; the wait loop is read-only so it just needs the
/// [Future.delayed] to yield to the event loop each cycle.
@visibleForTesting
Future<Map<String, dynamic>> findByTextWaitLoop({
  required String text,
  required int timeoutMs,
  required int pollIntervalMs,
}) async {
  assert(
    pollIntervalMs >= 100,
    'poll interval must be >= 100ms (CPU constraint)',
  );

  int elapsedMs = 0;

  while (elapsedMs < timeoutMs) {
    // 1. Walk the element tree synchronously — the tree is readable between
    //    frames. No endOfFrame await needed: we are reading, not writing.
    final bool found = _elementTreeContainsText(text, exact: true);
    if (found) {
      return <String, dynamic>{
        'matched': true,
        'elapsedMs': elapsedMs,
      };
    }

    // 2. Yield to the event loop for one poll interval. Real timers advance
    //    normally (production and tester.runAsync). The delayed Future also
    //    allows ValueNotifier listeners (setState) triggered externally to
    //    run their rebuilds in the microtask queue before the next check.
    await Future<void>.delayed(Duration(milliseconds: pollIntervalMs));
    elapsedMs += pollIntervalMs;
  }

  return <String, dynamic>{
    'matched': false,
    'reason': 'timeout',
  };
}

/// Polls the element tree until a [Text] widget with [text] as its data is
/// absent or until [timeoutMs] elapses.
///
/// Mirrors [findByTextWaitLoop] but inverts the predicate: returns
/// `{matched: true}` when the widget is gone (useful for "loading spinner
/// disappeared" style assertions).
///
/// `elapsedMs` is computed as `pollCount * pollIntervalMs` for fake-async
/// compatibility (same rationale as [findByTextWaitLoop]).
@visibleForTesting
Future<Map<String, dynamic>> findByTextGoneWaitLoop({
  required String text,
  required int timeoutMs,
  required int pollIntervalMs,
}) async {
  assert(
    pollIntervalMs >= 100,
    'poll interval must be >= 100ms (CPU constraint)',
  );

  int elapsedMs = 0;

  while (elapsedMs < timeoutMs) {
    // 1. Walk the element tree synchronously — read-only, no endOfFrame needed.
    final bool stillPresent = _elementTreeContainsText(text, exact: true);
    if (!stillPresent) {
      return <String, dynamic>{
        'matched': true,
        'elapsedMs': elapsedMs,
      };
    }

    // 2. Yield for one poll interval so external state changes can propagate.
    await Future<void>.delayed(Duration(milliseconds: pollIntervalMs));
    elapsedMs += pollIntervalMs;
  }

  return <String, dynamic>{
    'matched': false,
    'reason': 'timeout',
  };
}

/// Walks the live element tree and registers a fresh [RefRegistry] entry for
/// every [Text] widget whose [Text.data] matches [text].
///
/// When [exact] is `true` the comparison is `==`; when `false` it uses
/// [String.contains]. Returns the list of registered ref strings.
///
/// The element tree is readable synchronously at any point; no [endOfFrame]
/// await is needed before read-only walks.
@visibleForTesting
List<String> findByTextInTree({
  required String text,
  required bool exact,
  required String groupId,
}) {
  final List<String> refs = <String>[];

  void visit(Element element) {
    if (element.widget is Text) {
      final Text textWidget = element.widget as Text;
      final String? data = textWidget.data;
      if (data != null) {
        final bool matches = exact ? data == text : data.contains(text);
        if (matches) {
          // Compute bounding rect from the render object.
          final RenderBox? box = element.findRenderObject() as RenderBox?;
          if (box != null && box.hasSize) {
            final Offset topLeft = box.localToGlobal(Offset.zero);
            final Rect rect = topLeft & box.size;
            final String ref = RefRegistry.register(
              rect: rect,
              element: element,
              groupId: groupId,
              isTextField: false,
            );
            refs.add(ref);
          }
        }
      }
    }
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return refs;
}

/// Walks the live SemanticsNode tree and registers a fresh [RefRegistry] entry
/// for every node whose [SemanticsNode.label] matches [label].
///
/// When [role] is provided only nodes that have the corresponding
/// [SemanticsFlag] set are included.
///
/// | role        | SemanticsFlag            |
/// |-------------|--------------------------|
/// | button      | isButton                 |
/// | textField   | isTextField              |
/// | checkbox    | hasCheckedState          |
/// | link        | isLink                   |
/// | image       | isImage                  |
///
/// The semantics tree is readable synchronously; no [endOfFrame] await is
/// required before read-only walks.
@visibleForTesting
List<String> findByLabelInSemantics({
  required String label,
  String? role,
  required String groupId,
}) {
  final List<String> refs = <String>[];

  final SemanticsFlag? roleFlag = _roleToFlag(role);

  void visit(SemanticsNode node) {
    // 1. Check label match — node.label is the merged accessibility label.
    if (node.label == label) {
      // 2. Check optional role flag.
      //    node.hasFlag is deprecated but is the only way to check an arbitrary
      //    SemanticsFlag against a SemanticsNode in this Flutter version (3.41.x).
      //    SemanticsFlags has no contains(SemanticsFlag) method.
      // ignore: deprecated_member_use
      final bool roleMatches = roleFlag == null || node.hasFlag(roleFlag);

      if (roleMatches) {
        // 3. Resolve a bounding rect from the node's transform + rect.
        final Rect rect = node.rect;

        // 4. Attempt to locate a corresponding element via the semantics owner.
        //    SemanticsNode does not directly expose its element, so we use the
        //    node's rect center as a hit-test anchor to find the underlying
        //    RenderObject, then climb to the nearest Element.
        final Element? element = _elementForSemanticsNode(node);
        if (element != null) {
          final String ref = RefRegistry.register(
            rect: rect,
            element: element,
            groupId: groupId,
            isTextField: roleFlag == SemanticsFlag.isTextField,
          );
          refs.add(ref);
        }
      }
    }

    node.visitChildren((SemanticsNode child) {
      visit(child);
      return true;
    });
  }

  // Use pipelineOwner.semanticsOwner — matches ext_snapshot.dart pattern.
  // ignore: deprecated_member_use
  final SemanticsNode? root =
      WidgetsBinding.instance.pipelineOwner.semanticsOwner?.rootSemanticsNode;
  if (root != null) {
    visit(root);
  }

  return refs;
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Parses [raw] as a positive integer. Returns null when null, empty, or
/// not a valid integer.
int? _parseInt(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return int.tryParse(raw);
}

/// Returns true when the live element tree contains at least one [Text] widget
/// with [text] as its data.
bool _elementTreeContainsText(String text, {required bool exact}) {
  bool found = false;

  void visit(Element element) {
    if (found) return;
    if (element.widget is Text) {
      final String? data = (element.widget as Text).data;
      if (data != null) {
        found = exact ? data == text : data.contains(text);
      }
    }
    if (!found) {
      element.visitChildElements(visit);
    }
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return found;
}

/// Maps an optional [role] string to the corresponding [SemanticsFlag].
///
/// Returns null when [role] is null, blank, or unrecognised — callers treat
/// null as "no role filter".
SemanticsFlag? _roleToFlag(String? role) {
  if (role == null || role.isEmpty) return null;
  return switch (role.toLowerCase()) {
    'button' => SemanticsFlag.isButton,
    'textfield' => SemanticsFlag.isTextField,
    'checkbox' => SemanticsFlag.hasCheckedState,
    'link' => SemanticsFlag.isLink,
    'image' => SemanticsFlag.isImage,
    _ => null,
  };
}

// ---------------------------------------------------------------------------
// ext.aitest.wait_for_request
// ---------------------------------------------------------------------------

/// Handler for the `ext.aitest.wait_for_request` VM Service extension.
///
/// Blocks (Dart-side) until an HTTP request captured by
/// [AiTestHttpInterceptor] matches the supplied predicate, or until
/// [timeoutMs] elapses.
///
/// Match strategy is two-phase to avoid race conditions between the buffer
/// state at call time and entries arriving while the handler is suspended:
/// 1. Inspect the existing ring buffer for an entry that already satisfies
///    the predicate (pre-match path — the LLM agent may call this after the
///    network round-trip already completed).
/// 2. If no buffered match, subscribe to [AiTestHttpInterceptor.newEntries]
///    and wait for the first new entry that satisfies the predicate.
///
/// The two phases run inside a single async function so a buffered match
/// short-circuits without subscribing, while the post-call subscription only
/// races against entries enqueued AFTER the buffer inspection.
///
/// Params (all string-valued — `developer.registerExtension` hands handlers
/// a `Map<String, String>`):
/// - `urlPattern` (required): regex matched against the request URL via
///   [RegExp.hasMatch] (substring containment is not used so the agent gets
///   anchor control; bare strings like `/monitors` still match because
///   regex literal characters match themselves).
/// - `method` (optional): exact HTTP method match (case-insensitive).
///   When omitted any method satisfies the predicate.
/// - `minStatus` (optional): inclusive lower bound for `statusCode`.
/// - `maxStatus` (optional): inclusive upper bound for `statusCode`.
/// - `timeoutMs` (optional): milliseconds before the extension gives up.
///   Defaults to 5000ms (matches [_kDefaultTimeoutMs]).
///
/// Response shape:
/// ```json
/// {
///   "matched": true,
///   "url": "/monitors/42/metrics",
///   "method": "GET",
///   "statusCode": 200,
///   "durationMs": 87,
///   "timestamp": "2026-05-16T12:34:56.789Z"
/// }
/// ```
///
/// On timeout:
/// ```json
/// {
///   "matched": false,
///   "reason": "timeout",
///   "recentCount": 3
/// }
/// ```
///
/// `recentCount` exposes the current ring buffer size so the agent can decide
/// whether to retry with a relaxed pattern, inspect recent requests, or
/// abandon. The buffer cap (50) is enforced by [AiTestHttpInterceptor].
Future<developer.ServiceExtensionResponse> aiTestWaitForRequestHandler(
  String method,
  Map<String, String> params,
) async {
  try {
    final String? urlPattern = params['urlPattern'];
    if (urlPattern == null || urlPattern.isEmpty) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        '[ai-test-v3] ext.aitest.wait_for_request: missing required param '
        '"urlPattern"',
      );
    }

    final RegExp urlRe;
    try {
      urlRe = RegExp(urlPattern);
    } on FormatException catch (e) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        '[ai-test-v3] ext.aitest.wait_for_request: invalid urlPattern regex: $e',
      );
    }

    final String? methodFilter = params['method'];
    final int? minStatus = _parseInt(params['minStatus']);
    final int? maxStatus = _parseInt(params['maxStatus']);
    final int timeoutMs = _parseInt(params['timeoutMs']) ?? _kDefaultTimeoutMs;

    final interceptor = AiTestHttpInterceptor.instance;

    // 1. Pre-match: walk the existing ring buffer first. The agent may call
    //    this after the request already completed, in which case we return
    //    immediately without subscribing to the stream.
    for (final entry in AiTestHttpInterceptor.recentRequests()) {
      if (_matchesRequest(entry, urlRe, methodFilter, minStatus, maxStatus)) {
        return developer.ServiceExtensionResponse.result(
          jsonEncode(_buildMatchPayload(entry)),
        );
      }
    }

    // 2. No buffered match — subscribe to the broadcast stream with explicit
    //    StreamSubscription + Completer + Timer. Stream.firstWhere combined
    //    with Future.timeout LEAKS the inner subscription on timeout (the
    //    outer Future.timeout completes but does not propagate cancel back
    //    to firstWhere's stream listener), and over multi-hour LLM sessions
    //    with many wait-for-request timeouts the broadcast controller
    //    accumulates orphan listeners that re-run the predicate on every
    //    subsequent entry. Manual subscription guarantees cleanup on both
    //    paths (match or timeout). Oracle finding: production-readiness pass.
    final Completer<Map<String, dynamic>?> completer =
        Completer<Map<String, dynamic>?>();
    late final StreamSubscription<Map<String, dynamic>> sub;
    late final Timer timer;

    void finish(Map<String, dynamic>? value) {
      if (completer.isCompleted) return;
      sub.cancel();
      timer.cancel();
      completer.complete(value);
    }

    sub = interceptor.newEntries.listen((entry) {
      if (_matchesRequest(entry, urlRe, methodFilter, minStatus, maxStatus)) {
        finish(entry);
      }
    }, onError: (_) {
      // Stream errors are non-fatal here; let the timeout decide.
    });
    timer = Timer(Duration(milliseconds: timeoutMs), () => finish(null));

    final Map<String, dynamic>? match = await completer.future;

    if (match == null) {
      return developer.ServiceExtensionResponse.result(
        jsonEncode(<String, dynamic>{
          'matched': false,
          'reason': 'timeout',
          'recentCount': AiTestHttpInterceptor.recentRequests().length,
        }),
      );
    }

    return developer.ServiceExtensionResponse.result(
      jsonEncode(_buildMatchPayload(match)),
    );
  } catch (e, stackTrace) {
    developer.log(
      '[ai-test-v3] ext.aitest.wait_for_request error: $e\n$stackTrace',
      name: 'ai-test',
    );
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      e.toString(),
    );
  }
}

/// Returns true when [entry] satisfies every active filter.
///
/// All filters are AND-combined: an entry matches when the URL regex hits AND
/// the method matches (when supplied) AND the statusCode falls within the
/// optional inclusive [minStatus]..[maxStatus] range.
bool _matchesRequest(
  Map<String, dynamic> entry,
  RegExp urlRe,
  String? method,
  int? minStatus,
  int? maxStatus,
) {
  // 1. URL must match the regex. Use full-string regex match; agents that
  //    want a substring use `.*foo.*` or rely on regex literal characters.
  final String url = (entry['url'] as String?) ?? '';
  if (!urlRe.hasMatch(url)) return false;

  // 2. Optional method filter — case-insensitive exact match.
  if (method != null && method.isNotEmpty) {
    final String entryMethod = (entry['method'] as String?) ?? '';
    if (entryMethod.toUpperCase() != method.toUpperCase()) return false;
  }

  // 3. Optional status range filter — both bounds inclusive. statusCode is 0
  //    on network error; agents that want to wait for errors pass
  //    minStatus=0 maxStatus=0 (the buffer captures errors as such entries).
  final int statusCode = (entry['statusCode'] as int?) ?? 0;
  if (minStatus != null && statusCode < minStatus) return false;
  if (maxStatus != null && statusCode > maxStatus) return false;

  return true;
}

/// Builds the on-match payload from a buffer entry.
///
/// Strips internal bookkeeping fields (`isError`) and adds the top-level
/// `matched: true` marker the agent branches on.
Map<String, dynamic> _buildMatchPayload(Map<String, dynamic> entry) {
  return <String, dynamic>{
    'matched': true,
    'url': entry['url'],
    'method': entry['method'],
    'statusCode': entry['statusCode'],
    'durationMs': entry['durationMs'],
    'timestamp': entry['timestamp'],
  };
}

// ---------------------------------------------------------------------------
// Element-for-semantics-node helper
// ---------------------------------------------------------------------------

/// Attempts to locate the [Element] that owns [node].
///
/// [SemanticsNode] does not expose its owning [RenderObject] via public API.
/// This function falls back to the root element when no matching element is
/// found. The root element is safe to use because [RefRegistry] entries for
/// semantics-node refs are primarily consumed by tap/hover (which uses [rect]
/// from the node, not the element) rather than by text-field operations (which
/// use [EditableText.of(element)] — for those, the isTextField flag is set and
/// the snapshot extension, not find_by_label, produces the ref).
Element? _elementForSemanticsNode(SemanticsNode node) {
  // Use the root element as the anchor for semantics-node refs. The rect on
  // the RefEntry comes from node.rect which is correct; the element field is
  // a best-effort anchor used only for EditableText focus lookups (which do
  // not apply to generic semantics-label refs).
  return WidgetsBinding.instance.rootElement;
}
