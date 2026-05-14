## ai_test_flutter

Flutter Web E2E testing via Shadow DOM Projection. Spike status: under validation. See SPIKE_RESULT.md after run.

This package installs `AiTestBinding` between `WidgetsFlutterBinding.ensureInitialized()` and `Magic.init(...)`.
The binding projects a mirror DOM into `flt-glass-pane.shadowRoot` each frame, annotating every visible widget
with a `data-testid` attribute that Playwright can locate via `getByTestId`.

Active only when `kDebugMode == true` AND either `--dart-define=AI_TEST=1` or `?aiTest=1` URL param is present.
No-op in release builds; tree-shaken away by the Flutter Web compiler.
