// App-root smoke test. This file used to be `expect(true, isTrue)`, which
// passes whether or not the app can boot at all.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/main.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ConnectionManager> _manager(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  return ConnectionManager(await SharedPreferences.getInstance());
}

void main() {
  testWidgets('boots to the empty state with no saved connections',
      (tester) async {
    await tester.pumpWidget(HermesApp(connManager: await _manager({})));
    await tester.pumpAndSettle();

    expect(find.text('HERMES'), findsOneWidget);
    expect(find.text('No connections'), findsOneWidget);
    expect(find.byTooltip('Add Connection'), findsOneWidget);
  });

  testWidgets('lists a saved connection instead of the empty state',
      (tester) async {
    final manager = await _manager({});
    manager.saveConnection('Home', '192.168.1.50', 8642, 'secret');

    await tester.pumpWidget(HermesApp(connManager: manager));
    await tester.pumpAndSettle();

    expect(find.text('No connections'), findsNothing);
    expect(find.text('Home'), findsOneWidget);
    // Host, port and "has a key" tick, per _buildConnectionCard.
    expect(find.textContaining('192.168.1.50:8642'), findsOneWidget);
  });

  testWidgets('a corrupt stored connection is skipped, not fatal',
      (tester) async {
    // getConnections() deliberately swallows a bad entry rather than throwing,
    // because the callers have no try/catch around it.
    final manager = await _manager({
      'saved_connections': <String>['not even json', '{"id":"ok"}'],
    });
    manager.saveConnection('Good', 'host', 8642, 'k');

    await tester.pumpWidget(HermesApp(connManager: manager));
    await tester.pumpAndSettle();

    expect(find.text('Good'), findsOneWidget);
  });

  testWidgets('theme mode follows the stored preference', (tester) async {
    final dark = await _manager({'theme_mode': 'dark'});
    await tester.pumpWidget(HermesApp(connManager: dark));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );

    final system = await _manager({});
    await tester.pumpWidget(HermesApp(connManager: system));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
    );
  });
}
