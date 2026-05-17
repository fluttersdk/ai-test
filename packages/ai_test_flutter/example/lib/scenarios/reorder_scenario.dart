import 'package:flutter/material.dart';

/// `flutter_drag` regression guard.
///
/// Renders a [ReorderableListView] with three items. The integration test
/// calls `aiTestDragHandler` from the first item's snapshot ref to the
/// second item's ref and asserts the items reorder via the velocity-aware
/// pointer sequence the handler emits (Down + 5×Move + Up).
class ReorderScenario extends StatefulWidget {
  const ReorderScenario({super.key});

  @override
  State<ReorderScenario> createState() => _ReorderScenarioState();
}

class _ReorderScenarioState extends State<ReorderScenario> {
  final List<String> _items = <String>['alpha', 'bravo', 'charlie'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reorder (drag)')),
      body: ReorderableListView(
        padding: const EdgeInsets.all(16),
        onReorder: (int oldIndex, int newIndex) {
          setState(() {
            final int targetIndex =
                newIndex > oldIndex ? newIndex - 1 : newIndex;
            final String moved = _items.removeAt(oldIndex);
            _items.insert(targetIndex, moved);
          });
        },
        children: <Widget>[
          for (final String item in _items)
            ListTile(
              key: ValueKey<String>(item),
              title: Text(item),
              trailing: const Icon(Icons.drag_handle),
            ),
        ],
      ),
    );
  }
}
