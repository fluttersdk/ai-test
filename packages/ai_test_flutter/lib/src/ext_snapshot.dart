import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:magic/magic.dart';

import 'ref_registry.dart';
import 'v3_register.dart';

/// `ext.aitest.snapshot` — Step 6 of the V3 plan.
///
/// Walks the live [SemanticsOwner] tree and emits a Playwright-MCP-shaped
/// YAML accessibility snapshot. Each interactive node receives an
/// `[ref=eN]` token minted via [RefRegistry]; subsequent action tools
/// (`flutter_tap`, `flutter_type`, …) call [RefRegistry.lookup] to resolve
/// a token back to its hit point or focus target.
///
/// The Semantics tree is the primary structure (per Stage 3 D11): Wind
/// v1.0.0-alpha.7 already annotates seven widgets with `Semantics(button:
/// true, label: …)`, so the YAML output picks up those labels for free
/// without any per-widget bridging code.
///
/// MagicForm enrichment replaces the dropped `inspect_form` extension
/// (Oracle cull). For each interactive ref node we walk the Element tree
/// upward looking for the nearest [MagicForm] widget; if found and its
/// [MagicFormData] is bound to a text controller that matches the
/// interactive node's `EditableText`, we attach a `magicFormField: <name>`
/// line under the ref entry. Agents read form structure straight from the
/// snapshot — no separate roundtrip.
///
/// ## YAML shape
///
/// ```yaml
/// - text "Hello"
/// - button "Click" [ref=e1]
/// - textbox "Email" [ref=e2]
///     magicFormField: email
/// ```
///
/// ## Return envelope
///
/// ```json
/// {
///   "snapshot": "<yaml>",
///   "groupId": "snapshot-1700000000000"
/// }
/// ```
///
/// The returned `groupId` is what subsequent calls pass to
/// [RefRegistry.disposeGroup] when the snapshot is superseded.

// -----------------------------------------------------------------------------
// Public surface
// -----------------------------------------------------------------------------

/// Self-registers the `ext.aitest.snapshot` VM Service extension.
///
/// Call this once at plugin install time. Wave 3 modules each export a
/// `register*Extension` function; Step 14b (the aggregator) fans out to
/// every `register*Extension` entry from a single
/// `registerAllAiTestExtensions()` call.
///
/// Idempotent: repeated calls go through [registerExtensionIdempotent] and
/// the duplicate-registration `ArgumentError` is swallowed.
void registerSnapshotExtension() {
  // Gate at install: in release builds the entire plugin install path is
  // tree-shaken via the kIsWeb && kDebugMode guard in main.dart. We still
  // double-check here so a stray call from a non-debug context does not
  // pollute the VM extension table.
  if (!kDebugMode) {
    return;
  }
  registerExtensionIdempotent('ext.aitest.snapshot', aiTestSnapshotHandler);
}

/// VM Service extension handler for `ext.aitest.snapshot`.
///
/// Wraps [aiTestSnapshotBuild] in the
/// [developer.ServiceExtensionResponse] envelope expected by the Dart VM
/// Service RPC contract. Errors are converted to
/// [developer.ServiceExtensionResponse.error] (extension error code) so
/// the MCP server surfaces them as `{ isError: true }` envelopes rather
/// than crashing the isolate.
Future<developer.ServiceExtensionResponse> aiTestSnapshotHandler(
  String method,
  Map<String, String> params,
) async {
  try {
    final int? depth =
        params['depth'] != null ? int.tryParse(params['depth']!) : null;
    final Map<String, dynamic> payload =
        await aiTestSnapshotBuild(maxDepth: depth);
    return developer.ServiceExtensionResponse.result(jsonEncode(payload));
  } catch (e, stackTrace) {
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      jsonEncode(<String, String>{
        'error': e.toString(),
        'stackTrace': stackTrace.toString(),
      }),
    );
  }
}

/// Builds the snapshot payload directly, bypassing the VM Service
/// envelope. Exposed for widget tests and for any future caller that
/// wants the raw map.
///
/// [maxDepth] caps tree traversal — if `null`, the entire tree is
/// emitted.
///
/// Returns a map with two keys:
///
/// * `snapshot` — the YAML string;
/// * `groupId` — the [RefRegistry] group id under which every minted
///   token in this snapshot lives.
@visibleForTesting
Future<Map<String, dynamic>> aiTestSnapshotBuild({int? maxDepth}) async {
  // 1. Mint a fresh group id for this snapshot. Action tools resolve
  //    refs against the latest group; older groups can be cleaned up by
  //    the caller via RefRegistry.disposeGroup(groupId).
  final String groupId = 'snapshot-${DateTime.now().microsecondsSinceEpoch}';

  // 2. Make sure the Semantics owner is producing nodes. Without an
  //    active SemanticsHandle the rootSemanticsNode is null even when
  //    the binding is fully running. We retain the handle for the life
  //    of the snapshot build — releasing immediately after would let the
  //    framework drop the tree mid-walk on a different microtask.
  final SemanticsHandle handle = WidgetsBinding.instance.ensureSemantics();
  try {
    // 3. Build the SemanticsNode → Element index. The Semantics tree
    //    only exposes RenderObjects via debugSemantics; to get back to a
    //    BuildContext (needed for ancestor walks and EditableText
    //    lookup) we walk Elements once and record element.renderObject
    //    → element.
    final Map<RenderObject, Element> elementByRenderObject =
        _buildElementByRenderObject();

    // 4. Walk the Semantics tree top-down, emitting one YAML line per
    //    visited node. Interactive nodes also seed a RefRegistry entry.
    final SemanticsNode? root =
        WidgetsBinding.instance.pipelineOwner.semanticsOwner?.rootSemanticsNode;

    final StringBuffer buffer = StringBuffer();
    if (root != null) {
      _emitNode(
        node: root,
        depth: 0,
        maxDepth: maxDepth,
        buffer: buffer,
        groupId: groupId,
        elementByRenderObject: elementByRenderObject,
      );
    }

    return <String, dynamic>{
      'snapshot': buffer.toString(),
      'groupId': groupId,
    };
  } finally {
    handle.dispose();
  }
}

// -----------------------------------------------------------------------------
// Element-tree → SemanticsNode index
// -----------------------------------------------------------------------------

/// Builds a `RenderObject → Element` index by walking the live Element
/// tree once. The Semantics tree only exposes `RenderObject`s; to
/// recover a `BuildContext` for ancestor walks (MagicForm enrichment) and
/// for action tools that need `EditableText.of(...)`, we look the
/// element up by its render object.
///
/// O(N) over the Element tree per snapshot. Built fresh each call
/// because Element identity changes across rebuilds.
Map<RenderObject, Element> _buildElementByRenderObject() {
  final Map<RenderObject, Element> index = <RenderObject, Element>{};
  final Element? root = WidgetsBinding.instance.rootElement;
  if (root == null) {
    return index;
  }

  void visit(Element element) {
    final RenderObject? renderObject = element.renderObject;
    if (renderObject != null) {
      // Multiple Elements may share a RenderObject in theory (e.g. some
      // proxy widgets); keep the first (deepest-mounted, which is what
      // Element.visitChildElements visits first per parent). Subsequent
      // assignments would replace, so we only set when absent.
      index.putIfAbsent(renderObject, () => element);
    }
    element.visitChildElements(visit);
  }

  root.visitChildElements(visit);
  return index;
}

// -----------------------------------------------------------------------------
// Semantics walk + YAML emission
// -----------------------------------------------------------------------------

/// Emits one YAML line for [node] (and its descendants) into [buffer].
///
/// * Non-interactive nodes with text contribute a `- text "<value>"`
///   line; nodes with a non-empty label but no actionable role render
///   as `- text "<label>"` so screen-reader-only labels still surface.
/// * Interactive nodes (button, textbox, link, checkbox, image,
///   header, …) render as `- <role> "<label>" [ref=eN]` with a fresh
///   token minted via [RefRegistry]. When MagicForm enrichment finds a
///   bound field name, an indented `magicFormField: <name>` line follows.
/// * Pure structural nodes (no role, no text) recurse into their
///   children without emitting a line of their own — the depth indent is
///   measured relative to the deepest emitted ancestor.
void _emitNode({
  required SemanticsNode node,
  required int depth,
  required int? maxDepth,
  required StringBuffer buffer,
  required String groupId,
  required Map<RenderObject, Element> elementByRenderObject,
}) {
  if (maxDepth != null && depth > maxDepth) {
    return;
  }

  // 1. Read the merged SemanticsData snapshot. SemanticsNode exposes
  //    flags/actions/label individually but `getSemanticsData()` collapses
  //    transient mutations into a stable view.
  final SemanticsData data = node.getSemanticsData();
  final String label = data.label;
  final String value = data.value;

  // 2. Pick the role string. Order matters — textField wins over button
  //    when a custom widget sets both flags (mirrors Playwright MCP).
  final String? role = _roleFor(data);
  final bool interactive = _isInteractive(data);

  // 3. Render this node's line, when it has anything to say.
  int childDepth = depth;
  if (interactive && role != null) {
    final RenderObject? renderObject = _renderObjectFor(node);
    final Element? element =
        renderObject == null ? null : elementByRenderObject[renderObject];

    if (renderObject != null && element != null) {
      final Rect rect = _globalRectFor(renderObject);
      final String token = RefRegistry.register(
        rect: rect,
        element: element,
        groupId: groupId,
        isTextField: data.hasFlag(SemanticsFlag.isTextField),
        node: node,
        renderObject: renderObject,
      );

      buffer.write('${_indent(depth)}- $role "${_escape(label)}"');
      if (value.isNotEmpty) {
        buffer.write(': "${_escape(value)}"');
      }
      buffer.writeln(' [ref=$token]');

      // 3a. MagicForm enrichment — emit indented child line when we can
      //     trace back to a bound field name.
      final String? formField = _magicFormFieldFor(element);
      if (formField != null) {
        buffer.writeln('${_indent(depth + 1)}magicFormField: $formField');
      }

      childDepth = depth + 1;
    }
  } else if (label.isNotEmpty || value.isNotEmpty) {
    // 4. Non-interactive textual node. We emit it as a `text` line so
    //    agents can match by role even when nothing actionable is in
    //    play. Pure-structural nodes (no label, no value) skip emission
    //    and recurse silently.
    final String textValue = value.isNotEmpty ? value : label;
    buffer.writeln('${_indent(depth)}- text "${_escape(textValue)}"');
    childDepth = depth + 1;
  }

  // 5. Recurse into children. SemanticsNode.visitChildren returns true
  //    to continue visiting siblings; we always continue.
  node.visitChildren((SemanticsNode child) {
    _emitNode(
      node: child,
      depth: childDepth,
      maxDepth: maxDepth,
      buffer: buffer,
      groupId: groupId,
      elementByRenderObject: elementByRenderObject,
    );
    return true;
  });
}

/// Returns the Playwright-MCP-style role string for [data], or `null`
/// when the node has no addressable role (pure structural / decorative).
///
/// Flag precedence mirrors Playwright MCP's own resolver: textField →
/// checkbox → link → header → image → button. Generic `tap` actions on
/// otherwise unflagged nodes degrade to `button` so custom GestureDetector
/// trees still receive a token.
String? _roleFor(SemanticsData data) {
  if (data.hasFlag(SemanticsFlag.isTextField)) {
    return 'textbox';
  }
  if (data.hasFlag(SemanticsFlag.hasCheckedState)) {
    return 'checkbox';
  }
  if (data.hasFlag(SemanticsFlag.isLink)) {
    return 'link';
  }
  if (data.hasFlag(SemanticsFlag.isHeader)) {
    return 'heading';
  }
  if (data.hasFlag(SemanticsFlag.isImage)) {
    return 'image';
  }
  if (data.hasFlag(SemanticsFlag.isButton) ||
      data.hasAction(SemanticsAction.tap)) {
    return 'button';
  }
  return null;
}

/// Whether [data] should receive a `[ref=eN]` token. We mint refs for
/// any node that exposes a tap action OR that carries one of the
/// standard interactive flags. Nodes that only carry textual content
/// without a role render as `text` lines instead.
bool _isInteractive(SemanticsData data) {
  if (data.hasAction(SemanticsAction.tap)) {
    return true;
  }
  return data.hasFlag(SemanticsFlag.isTextField) ||
      data.hasFlag(SemanticsFlag.hasCheckedState) ||
      data.hasFlag(SemanticsFlag.isLink) ||
      data.hasFlag(SemanticsFlag.isButton) ||
      data.hasFlag(SemanticsFlag.isHeader) ||
      data.hasFlag(SemanticsFlag.isImage);
}

// -----------------------------------------------------------------------------
// SemanticsNode → RenderObject + global rect
// -----------------------------------------------------------------------------

/// Recovers the [RenderObject] that produced [node].
///
/// SemanticsNode exposes `owner` (the [SemanticsOwner]) but not the
/// originating render object. We probe the rootElement's RenderObject
/// graph for the first render object whose `debugSemantics` matches.
/// O(N) once per interactive node — acceptable on the small set of
/// interactive widgets a typical Flutter web screen renders.
RenderObject? _renderObjectFor(SemanticsNode node) {
  final Element? root = WidgetsBinding.instance.rootElement;
  if (root == null) {
    return null;
  }
  RenderObject? match;
  void visit(Element element) {
    if (match != null) {
      return;
    }
    final RenderObject? renderObject = element.renderObject;
    if (renderObject != null && identical(renderObject.debugSemantics, node)) {
      match = renderObject;
      return;
    }
    element.visitChildElements(visit);
  }

  root.visitChildElements(visit);
  return match;
}

/// Computes the global-coordinate [Rect] for [renderObject]. Falls back
/// to `Rect.zero` for render objects that are not [RenderBox] (e.g.
/// slivers). Action tools that depend on a real rect should re-derive
/// from the stored [RefEntry.renderObject] when needed.
Rect _globalRectFor(RenderObject renderObject) {
  if (renderObject is! RenderBox) {
    return Rect.zero;
  }
  if (!renderObject.hasSize) {
    return Rect.zero;
  }
  final Offset topLeft = renderObject.localToGlobal(Offset.zero);
  return topLeft & renderObject.size;
}

// -----------------------------------------------------------------------------
// MagicForm enrichment
// -----------------------------------------------------------------------------

/// Resolves the bound MagicForm field name for the interactive widget
/// at [element], or `null` when no enrichment applies.
///
/// Walk strategy (per Step 6 plan):
///
/// 1. Find the widget's nearest [EditableText] — a TextField, WInput,
///    WFormInput, or any other text input always renders an
///    EditableText leaf carrying its [TextEditingController].
/// 2. Walk ancestors via [Element.visitAncestorElements] looking for a
///    [MagicForm] widget instance with a non-null [MagicFormData].
/// 3. Compare the EditableText's controller against every
///    [TextEditingController] exposed by the form's `fieldNames`. The
///    first identity match wins.
///
/// Returns `null` (silently) when:
///
/// * the element has no descendant EditableText (e.g. checkbox, button);
/// * no ancestor MagicForm is found;
/// * the form has no `formData`;
/// * no controller in `formData` matches the EditableText's controller.
String? _magicFormFieldFor(Element element) {
  // 1. Locate the EditableText widget anywhere within this element.
  //    Most interactive ref nodes resolve to a single text field, but
  //    we traverse the subtree to handle wrappers (Material, decoration).
  final EditableText? editable = _findEditableTextWidget(element);
  if (editable == null) {
    return null;
  }
  final TextEditingController controller = editable.controller;

  // 2. Walk ancestors looking for the nearest MagicForm. We capture the
  //    widget instance (not the Element) — MagicForm is a StatelessWidget
  //    so its `formData` field is reachable directly off the widget.
  MagicForm? magicForm;
  element.visitAncestorElements((Element ancestor) {
    final Widget widget = ancestor.widget;
    if (widget is MagicForm) {
      magicForm = widget;
      return false; // stop; we want the NEAREST.
    }
    return true;
  });

  if (magicForm == null || magicForm!.formData == null) {
    return null;
  }
  final MagicFormData formData = magicForm!.formData!;

  // 3. Identity-match the EditableText's controller against every
  //    text controller exposed by the form. `MagicFormData` only
  //    exposes text controllers via `operator []`, which throws on
  //    non-text fields — guard with a try so we gracefully skip.
  for (final String fieldName in formData.fieldNames) {
    try {
      final TextEditingController formController = formData[fieldName];
      if (identical(formController, controller)) {
        return fieldName;
      }
    } on AssertionError {
      // Field is not a text controller; skip silently. Plan permits.
      continue;
    }
  }
  return null;
}

/// Returns the first [EditableText] widget found in the subtree rooted
/// at [start], or `null` when none exists.
EditableText? _findEditableTextWidget(Element start) {
  EditableText? found;
  void visit(Element element) {
    if (found != null) {
      return;
    }
    final Widget widget = element.widget;
    if (widget is EditableText) {
      found = widget;
      return;
    }
    element.visitChildElements(visit);
  }

  visit(start);
  return found;
}

// -----------------------------------------------------------------------------
// YAML helpers
// -----------------------------------------------------------------------------

/// Returns the indentation prefix for [depth]. Two spaces per level,
/// matching Playwright MCP's accessibility-tree output.
String _indent(int depth) => '  ' * depth;

/// Escapes characters that would break the YAML string layer. We only
/// emit double-quoted scalars, so backslash + double-quote are the only
/// characters that must be escaped. Control characters are passed
/// through — Flutter widgets do not generate them in label text.
String _escape(String input) =>
    input.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
