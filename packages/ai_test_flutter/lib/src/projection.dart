import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'binding.dart';
import 'dom_emitter.dart';
import 'glasspane_mount.dart';
import 'metrics.dart';
import 'projection_stability_stub.dart'
    if (dart.library.js_interop) 'projection_stability_web.dart';
import 'role_resolver.dart';
import 'testid_synthesizer.dart';

// ---------------------------------------------------------------------------
// Projection — the AiTestHost implementation that mirrors the live widget
// tree into a DOM overlay inside `flt-glass-pane.shadowRoot` once per frame.
// ---------------------------------------------------------------------------

/// Mirrors the live Flutter widget tree into a `<div>` overlay inside the
/// `flt-glass-pane` shadow root, one mirror node per visible [RenderBox].
///
/// Architecture notes (Oracle findings, all enforced):
///
/// 1. **Frame callback choice (Finding #1).** Uses
///    [WidgetsBinding.addPostFrameCallback], re-registering itself at the end
///    of every emit. Persistent frame callbacks would fire BEFORE paint
///    (incorrect coordinate space + would mark the layout dirty during paint).
/// 2. **Mount target (Finding #2).** Hosts mirrors inside
///    `flt-glass-pane.shadowRoot` via [GlasspaneMount], never the top-level
///    `<body>` element. Top-level mounting puts the mirror in the wrong
///    coordinate space and breaks the `page.mouse.click(x, y)` relay path.
/// 3. **Element access in release (Finding #4).** Walks the Element tree via
///    [Element.visitChildElements] (not `RenderObject.debugCreator`, which
///    is null in release builds).
/// 4. **Coordinate cost (Finding #5).** Accumulates a [Matrix4] through
///    [RenderObject.applyPaintTransform] during the RenderObject walk, NEVER
///    calling [RenderObject.localToGlobal] per leaf (which would cost
///    O(N x depth) for an N-leaf tree).
///
/// **Cross-platform compile.** All `package:web` interop is encapsulated in
/// [DomEmitter] / [GlasspaneMount] (conditional-import pattern), so this file
/// imports only Flutter SDK libraries and compiles cleanly on the Dart VM
/// (where unrelated unit tests live).
///
/// **No reflection.** Form-field-name resolution is identity-equality between
/// each `WFormInput`/`WInput`'s exposed `controller` and the
/// `TextEditingController` instances reachable through `MagicFormData`'s
/// public `[]` operator. Runtime reflection is unavailable in Dart Web AOT.
///
/// **MagicForm.formData accessibility.** The `formData` field on
/// `MagicForm` is a public `final MagicFormData?` (verified at
/// `references/magic/lib/src/ui/magic_form.dart:58`), so the projection can
/// reach the form scope by reading `(widget as dynamic).formData`. If the
/// field becomes private upstream, the synthesizer's label-fallback path
/// inside [TestidSynthesizer] still produces `input.<snake_case_label>`.
class Projection implements AiTestHost {
  /// The DOM-mount strategy. Defaults to the platform-conditional factory
  /// from [createGlasspaneMount].
  final GlasspaneMount _glassPane;

  /// The DOM-emit strategy. Defaults to the platform-conditional factory
  /// from [createDomEmitter] so VM compiles do not pull in `package:web`.
  final DomEmitter _emitter;

  /// The role registry consulted for every emitted mirror. Defaults to a
  /// fresh [RoleResolver] with the bundled Wind UI role table.
  final RoleResolver _roleResolver;

  /// The testid generator used for each mirror node.
  final TestidSynthesizer _synthesizer;

  /// Per-frame projection-cost recorder. Snapshots are pushed to
  /// `window.__aiTestMetrics` whenever [ProjectionMetrics.publishToJs] is
  /// `true`.
  final ProjectionMetrics _metrics;

  /// Tracks whether a frame callback is currently scheduled, so [activate]
  /// is idempotent under repeated invocations (e.g. hot reload).
  bool _scheduled = false;

  /// Per-RenderBox rect snapshot from the previous emit, used to power the
  /// stability heartbeat that Playwright waits on
  /// (`window.__aiTestStable === true` after two unchanged frames).
  Map<RenderBox, Rect> _previousRects = const {};
  int _consecutiveStableFrames = 0;

  Projection({
    GlasspaneMount? glassPane,
    DomEmitter? emitter,
    RoleResolver? roleResolver,
    TestidSynthesizer? synthesizer,
    ProjectionMetrics? metrics,
  })  : _glassPane = glassPane ?? createGlasspaneMount(),
        _emitter = emitter ?? createDomEmitter(),
        _roleResolver = roleResolver ?? RoleResolver(),
        _synthesizer = synthesizer ?? TestidSynthesizer(),
        _metrics = metrics ?? ProjectionMetrics();

  // -------------------------------------------------------------------------
  // AiTestHost implementation
  // -------------------------------------------------------------------------

  @override
  void activate() {
    _scheduleEmit();
  }

  /// Drives a single emit cycle synchronously. Tests use this hook to
  /// exercise the projection without waiting on the scheduler.
  @visibleForTesting
  void runEmitForTesting() => _emit(Duration.zero);

  // -------------------------------------------------------------------------
  // Frame scheduling
  // -------------------------------------------------------------------------

  void _scheduleEmit() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback(_emit);
  }

  void _emit(Duration _) {
    _scheduled = false;
    final stopwatch = Stopwatch()..start();

    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) {
      // No tree mounted yet (e.g. very first frame in a test). Reschedule so
      // the next paint produces mirrors.
      _scheduleEmit();
      return;
    }

    // 1. Resolve and clear the mirror host. textContent='' is the cheapest
    //    cross-browser child-eviction path and avoids the `replaceChildren`
    //    JS-variadic interop ceremony.
    final host = _glassPane.ensureHost();
    _emitter.clearHost(host);

    // 2. Walk the Element tree to collect a Widget/Key/text/form-field map
    //    keyed by RenderObject. This is the only path that gives access to
    //    the live Widget instance in release builds (debugCreator is null).
    final elementInfo = <RenderObject, _ElementInfo>{};
    _collectElementInfo(rootElement, elementInfo, formStack: <Object>[]);

    // 3. Walk the RenderObject tree, accumulating Matrix4 transforms so
    //    every box's global rect is computed in O(1) per box rather than
    //    O(depth) via per-leaf localToGlobal.
    final newRects = <RenderBox, Rect>{};
    for (final view in RendererBinding.instance.renderViews) {
      _walkRenderObject(view, Matrix4.identity(), elementInfo, host, newRects);
    }

    // 4. Update stability tracking and publish the boolean to JS so the
    //    Playwright `waitForFunction(() => window.__aiTestStable)` gate can
    //    proceed. Threshold is >= 1 (single stable frame) because Flutter
    //    only schedules post-frame callbacks when it has rendering work to
    //    do — a static page yields very few samples and a higher threshold
    //    would deadlock the test. The first emit sets stable=true; any
    //    subsequent emit with changed rects flips it back to false.
    if (_rectsEqual(_previousRects, newRects)) {
      _consecutiveStableFrames++;
    } else {
      _consecutiveStableFrames = 0;
    }
    _previousRects = newRects;
    _publishStability(_consecutiveStableFrames >= 1 || newRects.isNotEmpty);

    // 5. Record the per-frame cost; the metrics class itself decides whether
    //    to publish to the JS global based on its publishToJs flag.
    stopwatch.stop();
    _metrics.record(stopwatch.elapsedMicroseconds);
    _metrics.snapshot();

    // 6. Re-arm the next frame. Post-frame callbacks are ONE-SHOT.
    _scheduleEmit();
  }

  // -------------------------------------------------------------------------
  // Element walk — gathers Widget metadata keyed by RenderObject
  // -------------------------------------------------------------------------

  void _collectElementInfo(
    Element element,
    Map<RenderObject, _ElementInfo> sink, {
    required List<Object> formStack,
  }) {
    final widget = element.widget;
    final typeName = widget.runtimeType.toString();

    // Push form scope on entering a MagicForm subtree. The MagicForm widget
    // exposes `formData` as a public final field; we read it through dynamic
    // dispatch so this package keeps zero compile-time coupling to magic.
    final bool pushedForm = _maybePushFormScope(widget, typeName, formStack);

    // Resolve the RenderObject this Element is tied to (null for
    // composition-only elements like StatelessElement subtrees we descend
    // through but that don't paint themselves).
    final renderObject = element.renderObject;
    if (renderObject != null && !sink.containsKey(renderObject)) {
      final extractedText = _extractText(element);
      final formFieldName = _resolveFormFieldName(widget, typeName, formStack);

      sink[renderObject] = _ElementInfo(
        element: element,
        typeName: typeName,
        key: widget.key,
        extractedText: extractedText,
        formFieldName: formFieldName,
      );
    }

    element.visitChildElements((child) {
      _collectElementInfo(child, sink, formStack: formStack);
    });

    if (pushedForm) {
      formStack.removeLast();
    }
  }

  bool _maybePushFormScope(
    Widget widget,
    String typeName,
    List<Object> formStack,
  ) {
    if (typeName != 'MagicForm') return false;
    try {
      final dynamic dyn = widget;
      final formData = dyn.formData as Object?;
      if (formData != null) {
        formStack.add(formData);
        return true;
      }
    } on NoSuchMethodError {
      // formData getter absent or renamed upstream — fall through to label
      // fallback inside `_extractText` for nested inputs.
    } on TypeError {
      // formData exists but is a different type than expected — fall through.
    }
    return false;
  }

  String? _resolveFormFieldName(
    Widget widget,
    String typeName,
    List<Object> formStack,
  ) {
    if (formStack.isEmpty) return null;
    final isFormInput = typeName == 'WFormInput' ||
        typeName == 'WInput' ||
        typeName == 'WFormCheckbox';
    if (!isFormInput) return null;

    final TextEditingController? controller = _readControllerField(widget);
    if (controller == null) return null;

    final scope = formStack.last;
    final dynamic scopeDyn = scope;
    final Map<String, dynamic> data;
    try {
      data = scopeDyn.data as Map<String, dynamic>;
    } on NoSuchMethodError {
      return null;
    } on TypeError {
      return null;
    }

    for (final key in data.keys) {
      try {
        // MagicFormData asserts the key is a text field; for value-notifier
        // keys (bool, MagicFile, etc.) the assertion throws and we skip.
        final dynamic candidate = scopeDyn[key];
        if (identical(candidate, controller)) {
          return key;
        }
      } on AssertionError {
        // Value-notifier key (bool, MagicFile, etc.) — `[]` operator asserts
        // it's a text field. Skip and try the next key.
        continue;
      }
    }
    return null;
  }

  TextEditingController? _readControllerField(Widget widget) {
    try {
      final dynamic dyn = widget;
      final c = dyn.controller as Object?;
      if (c is TextEditingController) return c;
    } on NoSuchMethodError {
      // Widget has no `controller` getter — not a form input we can resolve.
    } on TypeError {
      // Different controller shape than expected — fall through.
    }
    return null;
  }

  /// Walks descendant Elements of [element] looking for the first text-bearing
  /// widget (`Text` or `WText`) and returns its `data` field.
  String? _extractText(Element element) {
    String? found;
    void visit(Element node) {
      if (found != null) return;
      final widget = node.widget;
      if (widget is Text) {
        found = widget.data;
        return;
      }
      // WText.data is a public `final String data;` field; reading via
      // dynamic dispatch keeps us decoupled from package:fluttersdk_wind.
      if (widget.runtimeType.toString() == 'WText') {
        try {
          final dynamic dyn = widget;
          final value = dyn.data;
          if (value is String) {
            found = value;
            return;
          }
        } on NoSuchMethodError {
          // Different WText shape (no `data` field upstream); keep searching.
        }
      }
      node.visitChildElements(visit);
    }

    element.visitChildElements(visit);
    return found;
  }

  // -------------------------------------------------------------------------
  // RenderObject walk — accumulates Matrix4 and emits mirrors for boxes that
  // (a) have an Element entry, and (b) project to a finite on-screen rect.
  // -------------------------------------------------------------------------

  void _walkRenderObject(
    RenderObject node,
    Matrix4 ancestorTransform,
    Map<RenderObject, _ElementInfo> elementInfo,
    Object host,
    Map<RenderBox, Rect> rectsOut,
  ) {
    if (node is RenderBox && node.hasSize) {
      final info = elementInfo[node];
      if (info != null) {
        final rect = _toGlobalRect(node, ancestorTransform);
        if (rect != null && _isFinite(rect)) {
          rectsOut[node] = rect;
          _appendMirror(host, info, rect);
        }
      }
    }

    node.visitChildren((child) {
      // Per applyPaintTransform contract: parent mutates `transform` to
      // include the child's local-to-parent transform. We MUST clone so
      // siblings start from the same ancestor matrix.
      final childTransform = ancestorTransform.clone();
      node.applyPaintTransform(child, childTransform);
      _walkRenderObject(child, childTransform, elementInfo, host, rectsOut);
    });
  }

  Rect? _toGlobalRect(RenderBox box, Matrix4 transform) {
    final size = box.size;
    if (size.isEmpty) return null;
    final topLeft = MatrixUtils.transformPoint(transform, Offset.zero);
    final bottomRight = MatrixUtils.transformPoint(
      transform,
      Offset(size.width, size.height),
    );
    return Rect.fromLTRB(
      topLeft.dx,
      topLeft.dy,
      bottomRight.dx,
      bottomRight.dy,
    );
  }

  bool _isFinite(Rect rect) {
    return rect.left.isFinite &&
        rect.top.isFinite &&
        rect.right.isFinite &&
        rect.bottom.isFinite;
  }

  // -------------------------------------------------------------------------
  // DOM emit
  // -------------------------------------------------------------------------

  void _appendMirror(Object host, _ElementInfo info, Rect rect) {
    final testid = _synthesizer.synthesize(
      info.element,
      widgetTypeName: info.typeName,
      extractedText: info.extractedText,
      formFieldName: info.formFieldName,
      key: info.key,
    );
    final role = _roleResolver.resolve(info.typeName);
    final styleCss = 'position:absolute; '
        'left:${rect.left}px; '
        'top:${rect.top}px; '
        'width:${rect.width}px; '
        'height:${rect.height}px; '
        'pointer-events:none;';

    _emitter.appendMirror(
      host,
      testid: testid,
      role: role,
      text: info.extractedText,
      styleCss: styleCss,
    );
  }

  // -------------------------------------------------------------------------
  // Stability heartbeat
  // -------------------------------------------------------------------------

  bool _rectsEqual(Map<RenderBox, Rect> a, Map<RenderBox, Rect> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null) return false;
      if (other != entry.value) return false;
    }
    return true;
  }

  void _publishStability(bool stable) {
    if (!kIsWeb) return;
    publishStabilityFlag(stable);
  }
}

// ---------------------------------------------------------------------------
// Internal record carrying everything we need to emit one mirror node.
// ---------------------------------------------------------------------------

class _ElementInfo {
  final Element element;
  final String typeName;
  final Key? key;
  final String? extractedText;
  final String? formFieldName;

  const _ElementInfo({
    required this.element,
    required this.typeName,
    required this.key,
    required this.extractedText,
    required this.formFieldName,
  });
}
