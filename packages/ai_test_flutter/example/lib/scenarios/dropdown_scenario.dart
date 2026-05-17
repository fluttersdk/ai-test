import 'package:flutter/material.dart';

/// `flutter_select_option` regression guard.
///
/// Renders a [DropdownButton] with three values. The integration test calls
/// `aiTestSelectOptionHandler` against the dropdown's snapshot ref to verify
/// the handler invokes `onChanged` directly without going through hit-test.
class DropdownScenario extends StatefulWidget {
  const DropdownScenario({super.key});

  @override
  State<DropdownScenario> createState() => _DropdownScenarioState();
}

class _DropdownScenarioState extends State<DropdownScenario> {
  String _selected = 'apple';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dropdown (select_option)')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Pick a fruit'),
            DropdownButton<String>(
              value: _selected,
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem<String>(value: 'apple', child: Text('Apple')),
                DropdownMenuItem<String>(
                    value: 'banana', child: Text('Banana')),
                DropdownMenuItem<String>(
                    value: 'cherry', child: Text('Cherry')),
              ],
              onChanged: (String? next) {
                if (next == null) return;
                setState(() => _selected = next);
              },
            ),
            const SizedBox(height: 16),
            Text('Selected: $_selected'),
          ],
        ),
      ),
    );
  }
}
