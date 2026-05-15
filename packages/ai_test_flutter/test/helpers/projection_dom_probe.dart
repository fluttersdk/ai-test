import 'package:web/web.dart' as web;

/// A single emitted mirror node, parsed from `data-*` attributes for assertions.
class ProjectionMirror {
  final String? testid;
  final String? role;
  final String? text;
  final String style;

  const ProjectionMirror({
    required this.testid,
    required this.role,
    required this.text,
    required this.style,
  });
}

/// Reads every `<div>` currently inside `flt-glass-pane.shadowRoot > #ai-test-host`
/// and returns one [ProjectionMirror] per child.
///
/// Returns an empty list when the host has not been mounted yet OR when the
/// glass pane is unavailable in the test environment.
List<ProjectionMirror> collectProjectionMirrors() {
  final glassPane = web.document.querySelector('flt-glass-pane');
  if (glassPane == null) return const [];

  final shadowRoot = glassPane.shadowRoot;
  if (shadowRoot == null) return const [];

  final host = shadowRoot.querySelector('#ai-test-host');
  if (host == null) return const [];

  final result = <ProjectionMirror>[];
  final children = host.children;
  for (var i = 0; i < children.length; i++) {
    final node = children.item(i);
    if (node == null) continue;
    final element = node;
    result.add(
      ProjectionMirror(
        testid: element.getAttribute('data-testid'),
        role: element.getAttribute('data-role'),
        text: element.getAttribute('data-text'),
        style: element.getAttribute('style') ?? '',
      ),
    );
  }
  return result;
}
