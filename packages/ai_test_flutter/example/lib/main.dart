import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';

void main() {
  runApp(const MaterialApp(home: ProbeView()));
}

/// Phase 0 probe screen.
///
/// Renders a fixed 200x80 button at viewport center. Every click increments
/// [window.__probeClickCount] so Playwright can assert the value without
/// relying on locator APIs (bypassed by canvas rendering).
class ProbeView extends StatelessWidget {
  const ProbeView({super.key});

  void _bumpCounter() {
    final current =
        (globalContext['__probeClickCount'] as JSNumber?)?.toDartInt ?? 0;
    globalContext['__probeClickCount'] = (current + 1).toJS;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 200,
          height: 80,
          child: ElevatedButton(
            onPressed: _bumpCounter,
            child: const Text('PROBE'),
          ),
        ),
      ),
    );
  }
}
