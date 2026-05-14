/// Flutter Web E2E testing via Shadow DOM Projection.
///
/// This barrel is the only public API of the ai_test_flutter package.
library;

export 'src/binding.dart' show AiTestBinding, AiTestHost;
export 'src/glasspane_mount.dart' show GlasspaneMount, createGlasspaneMount;
export 'src/metrics.dart' show MetricsSnapshot, ProjectionMetrics;
export 'src/role_resolver.dart' show RoleResolver;
export 'src/testid_synthesizer.dart' show TestidSynthesizer;
