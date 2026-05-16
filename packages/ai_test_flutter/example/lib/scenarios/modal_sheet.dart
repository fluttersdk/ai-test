import 'package:flutter/material.dart';

/// Scenario 3 — D3 + D10 modal handling regression guard.
///
/// Renders a button that opens a [showModalBottomSheet]. The sheet has a Close
/// button (manual dismiss path) and a scrim (tap-outside dismiss path). A
/// visible counter tracks whether the sheet is open or closed.
///
/// D3: `flutter_navigate` must auto-pop modal routes before pushing the new
/// page so stuck overlays do not block the new route.
///
/// D10: `flutter_dismiss_modals` explicitly pops every modal above the current
/// page route without disturbing the page navigation stack.
///
/// The integration test calls `aiTestDismissModalsHandler` after opening the
/// sheet and asserts the popped count + the closed state.
class ModalSheetScenario extends StatefulWidget {
  const ModalSheetScenario({super.key});

  /// Label of the button that opens the sheet.
  static const String openLabel = 'Open sheet';

  /// Title rendered inside the modal sheet. Tests look for it to verify the
  /// sheet is currently open vs dismissed.
  static const String sheetTitle = 'Modal sheet body';

  /// Label of the close button inside the sheet.
  static const String closeLabel = 'Close';

  @override
  State<ModalSheetScenario> createState() => _ModalSheetScenarioState();
}

class _ModalSheetScenarioState extends State<ModalSheetScenario> {
  bool _sheetOpen = false;

  Future<void> _openSheet() async {
    setState(() => _sheetOpen = true);

    // showModalBottomSheet returns when the sheet is dismissed (by close
    // button, scrim tap, or programmatic pop). Reset the visible flag so the
    // counter reflects state on every dismissal path.
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                ModalSheetScenario.sheetTitle,
                style: TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: const Text(ModalSheetScenario.closeLabel),
              ),
            ],
          ),
        ),
      ),
    );

    if (!mounted) return;
    setState(() => _sheetOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Modal sheet (D3 + D10)')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            // 1. Sheet-state display — integration test assertion target.
            //    Uses words ("open" / "closed") instead of a bool toggle so
            //    the test can pin literal text.
            Text(
              'Sheet: ${_sheetOpen ? 'open' : 'closed'}',
              style: const TextStyle(fontSize: 20),
            ),
            const SizedBox(height: 24),
            // 2. Open trigger.
            ElevatedButton(
              onPressed: _openSheet,
              child: const Text(ModalSheetScenario.openLabel),
            ),
          ],
        ),
      ),
    );
  }
}
