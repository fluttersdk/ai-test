import 'ext_mock_http.dart';
import 'ext_navigation.dart';
import 'ext_network_console.dart';
import 'ext_pointer.dart';
import 'ext_screenshot.dart';
import 'ext_scroll.dart';
import 'ext_snapshot.dart';
import 'ext_text_input.dart';
import 'ext_wait_find.dart';

/// Registers every `ext.aitest.*` extension owned by the V3 ai_test plugin.
///
/// This aggregator is called once from [AiTestPluginV3.install] during app
/// initialization. It coordinates the self-registering Wave 3 extension modules
/// in a single entry point, ensuring idempotency via each module's own calls to
/// [registerExtensionIdempotent].
///
/// Each call is sequential but idempotent (safe to call multiple times during
/// hot-restart). The registration order does not affect functionality, but we
/// keep a stable order for readability.
void registerAllAiTestExtensions() {
  // 1. Snapshot: Semantics tree walk + ref system + field enrichment.
  registerSnapshotExtension();

  // 2. Pointer: tap + hover + drag handlers.
  registerPointerExtensions();

  // 3. Text input: type + press_key handlers.
  registerTextInputExtensions();

  // 4. Scroll: scroll + select_option handlers.
  registerScrollExtensions();

  // 5. Navigation: navigate + navigate_back + get_routes handlers.
  registerNavigationExtensions();

  // 6. Screenshot: RepaintBoundary.toImage → JPEG/PNG.
  registerScreenshotExtension();

  // 7. Network console: read Dio ring buffer.
  registerNetworkConsoleExtensions();

  // 8. Mock HTTP: inject fake Dio responses.
  registerMockHttpExtension();

  // 9. Wait + find: wait_for + find_by_text + find_by_label.
  registerWaitFindExtensions();
}

/// Resets any extension state for testing.
///
/// Most Wave 3 modules are stateless (they read runtime state from the running
/// app). This function is a hook for future modules that accumulate state
/// (e.g., caches, collected data). Currently it defers to the individual
/// modules' own reset strategies if they exist.
///
/// Called from test setup or reset scenarios.
void resetForTesting() {
  // Placeholder: individual modules defer their reset logic.
  // No global state to clear at the aggregator level.
}
