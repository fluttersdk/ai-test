import 'package:flutter/material.dart';

/// Scenario 2 — D2 + DEFECT-6 regression guard.
///
/// Mirrors the `MonitorAssignList` row shape: an outer `InkWell` wrapping a
/// Row of [Icon] + [Text]. Selection state lives on the outer recognizer; the
/// inner icon swaps between unchecked / checked variants to reflect it.
///
/// DEFECT-6 (QA-3): tapping the row in MonitorAssignList did not toggle the
/// selection because the ref resolved to the inner label, not the outer
/// recognizer. Post-D2 the gesture binding's hit-test sweeps the ancestor
/// chain so the row toggles correctly regardless of which descendant the ref
/// points at.
class CheckboxRowScenario extends StatefulWidget {
  const CheckboxRowScenario({super.key});

  /// Visible label inside the row. Tests target it with `find.text(...)` to
  /// verify the inner-text tap path reaches the ancestor recognizer.
  static const String label = 'Monitor #1';

  @override
  State<CheckboxRowScenario> createState() => _CheckboxRowScenarioState();
}

class _CheckboxRowScenarioState extends State<CheckboxRowScenario> {
  bool _selected = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Checkbox row (DEFECT-6)')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            // 1. Selection counter — integration test assertion target.
            Text(
              'Selected: ${_selected ? 1 : 0}',
              style: const TextStyle(fontSize: 20),
            ),
            const SizedBox(height: 24),
            // 2. Ancestor InkWell wrapping the row. The icon switches between
            //    unchecked / checked variants on each tap, mirroring the
            //    MonitorAssignList layout exactly.
            Material(
              color: _selected ? Colors.green.shade100 : Colors.grey.shade200,
              child: InkWell(
                onTap: () => setState(() => _selected = !_selected),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        _selected
                            ? Icons.check_box
                            : Icons.check_box_outline_blank,
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        CheckboxRowScenario.label,
                        style: TextStyle(fontSize: 16),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
