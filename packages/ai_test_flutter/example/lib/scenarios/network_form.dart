import 'package:flutter/material.dart';

/// Signature for the network call the scenario fires when its submit button
/// is tapped.
///
/// Returns the HTTP status code of the response. Throws on network error.
/// Injectable so integration tests can stub the round-trip without hitting
/// the public internet.
typedef NetworkFetcher = Future<int> Function(Uri url, Object? body);

/// Scenario 4 — D9 regression guard.
///
/// Renders a button that POSTs a fixed payload to `jsonplaceholder.typicode.com`
/// (the production fetcher) or to a test stub (when injected). On each
/// successful response a visible counter increments.
///
/// D9: the plugin's `ext.aitest.wait_for_request` handler subscribes to the
/// `AiTestHttpInterceptor` ring buffer. The integration test routes the
/// scenario's fetcher through the interceptor (via its public Magic-typed
/// `onRequest` / `onResponse` surface) so the D9 handler observes the request
/// without any real network traffic.
class NetworkFormScenario extends StatefulWidget {
  const NetworkFormScenario({super.key, required this.fetcher});

  /// Network call invoked when the submit button is tapped. The example app's
  /// `main.dart` wires a `package:http` fetcher in production; integration
  /// tests supply a stub that records into the interceptor.
  final NetworkFetcher fetcher;

  /// Label of the submit button. Integration tests target it with
  /// `find.text(NetworkFormScenario.submitLabel)`.
  static const String submitLabel = 'Submit';

  /// Endpoint the scenario hits. Exposed so the integration test can build a
  /// regex pattern that matches the URL the interceptor records.
  static final Uri endpoint =
      Uri.parse('https://jsonplaceholder.typicode.com/posts');

  @override
  State<NetworkFormScenario> createState() => _NetworkFormScenarioState();
}

class _NetworkFormScenarioState extends State<NetworkFormScenario> {
  int _responses = 0;
  bool _inFlight = false;
  String? _lastError;

  Future<void> _submit() async {
    if (_inFlight) return;
    setState(() {
      _inFlight = true;
      _lastError = null;
    });

    try {
      final status = await widget.fetcher(
        NetworkFormScenario.endpoint,
        const <String, dynamic>{
          'title': 'ai-test fixture',
          'body': 'D9 regression payload',
          'userId': 1,
        },
      );

      if (!mounted) return;
      // Treat any 2xx as success. The test fixture returns 201 to mirror the
      // public jsonplaceholder behaviour.
      if (status >= 200 && status < 300) {
        setState(() => _responses += 1);
      } else {
        setState(() => _lastError = 'HTTP $status');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _lastError = e.toString());
    } finally {
      if (mounted) {
        setState(() => _inFlight = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Network form (D9)')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            // 1. Response counter — integration test assertion target.
            Text(
              'Responses: $_responses',
              style: const TextStyle(fontSize: 20),
            ),
            const SizedBox(height: 8),
            if (_lastError != null)
              Text(
                'Error: $_lastError',
                style: const TextStyle(color: Colors.red),
              ),
            const SizedBox(height: 24),
            // 2. Submit trigger. Disabled while a request is in flight so the
            //    counter cannot double-increment from a double tap.
            ElevatedButton(
              onPressed: _inFlight ? null : _submit,
              child: const Text(NetworkFormScenario.submitLabel),
            ),
          ],
        ),
      ),
    );
  }
}
