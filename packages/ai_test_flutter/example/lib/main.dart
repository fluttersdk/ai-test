import 'dart:convert';

import 'package:ai_test_flutter/ai_test_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'scenarios/checkbox_row.dart';
import 'scenarios/modal_sheet.dart';
import 'scenarios/network_form.dart';
import 'scenarios/wbutton_nested.dart';

/// T2 fixture app entry point.
///
/// Boots a minimal MaterialApp with named routes to four regression-guard
/// scenarios (D2, DEFECT-6, D3 + D10, D9). The plugin is installed under the
/// canonical `kIsWeb && kDebugMode` gate so the example app behaves the same
/// way as the production uptizm-app wires it.
///
/// Integration tests boot the app via [AiTestExampleApp] directly (skipping
/// `runApp`) and override the [AiTestExampleApp.networkFetcher] so the D9
/// scenario does not hit the public internet.
void main() {
  // Same compile-time guard as uptizm-app/lib/main.dart. Release builds tree-
  // shake the whole plugin install path.
  if (kIsWeb && kDebugMode) {
    AiTestPluginV3.install();
  }

  runApp(
    RepaintBoundary(
      key: AiTestPluginV3.rootRepaintBoundaryKey,
      child: const AiTestExampleApp(),
    ),
  );
}

/// Default production [NetworkFetcher] — POSTs the payload via `package:http`.
///
/// Returns the response status code. Exposed at top-level so it can be passed
/// as a const-time default to [AiTestExampleApp] without capturing closure
/// state.
Future<int> _httpPostFetcher(Uri url, Object? body) async {
  final response = await http.post(
    url,
    headers: <String, String>{'content-type': 'application/json'},
    body: jsonEncode(body),
  );
  return response.statusCode;
}

/// Root widget of the fixture app.
///
/// Routes:
/// * `/`         — landing index with links to each scenario.
/// * `/wbutton`  — Scenario 1 (D2).
/// * `/checkbox` — Scenario 2 (DEFECT-6).
/// * `/modal`    — Scenario 3 (D3 + D10).
/// * `/network`  — Scenario 4 (D9).
///
/// [initialRoute] is exposed so integration tests can boot directly into a
/// scenario without navigating through the index.
///
/// [networkFetcher] is the round-trip function the [NetworkFormScenario]
/// invokes. Defaults to [_httpPostFetcher] for production; tests override it
/// with a stub that records into the `AiTestHttpInterceptor`.
class AiTestExampleApp extends StatelessWidget {
  const AiTestExampleApp({
    super.key,
    this.initialRoute = '/',
    this.networkFetcher = _httpPostFetcher,
  });

  /// Route the MaterialApp boots at. `/` shows the index; scenario paths
  /// jump straight into the regression-guard widgets.
  final String initialRoute;

  /// Network round-trip used by the D9 scenario. Production builds use
  /// [_httpPostFetcher]; integration tests inject a stub that pumps the
  /// interceptor's ring buffer directly.
  final NetworkFetcher networkFetcher;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ai_test_flutter fixture',
      initialRoute: initialRoute,
      routes: <String, WidgetBuilder>{
        '/': (BuildContext context) => const _IndexPage(),
        '/wbutton': (BuildContext context) => const WButtonNestedScenario(),
        '/checkbox': (BuildContext context) => const CheckboxRowScenario(),
        '/modal': (BuildContext context) => const ModalSheetScenario(),
        '/network': (BuildContext context) =>
            NetworkFormScenario(fetcher: networkFetcher),
      },
    );
  }
}

/// Landing page that links to each scenario route. Plain ListTiles — the
/// fixture intentionally avoids Wind UI / Magic to keep its dependency
/// surface to vanilla Flutter.
class _IndexPage extends StatelessWidget {
  const _IndexPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ai_test fixture')),
      body: ListView(
        children: <Widget>[
          ListTile(
            title: const Text('WButton nested (D2)'),
            onTap: () => Navigator.of(context).pushNamed('/wbutton'),
          ),
          ListTile(
            title: const Text('Checkbox row (DEFECT-6)'),
            onTap: () => Navigator.of(context).pushNamed('/checkbox'),
          ),
          ListTile(
            title: const Text('Modal sheet (D3 + D10)'),
            onTap: () => Navigator.of(context).pushNamed('/modal'),
          ),
          ListTile(
            title: const Text('Network form (D9)'),
            onTap: () => Navigator.of(context).pushNamed('/network'),
          ),
        ],
      ),
    );
  }
}
