// WorkflowBindingEditorScreen: the flat-graph-only list editor that replaced
// the node canvas. Covers row derivation (grouped by node, connections
// skipped), inline value edits, the expose-as-binding toggle, search/filter
// with collapse-state restoration, Save-blocking validation, the
// showNameAndKind import mode, pre-population parity, and Cancel discarding
// local edits.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';
import 'package:hermes_android/core/widgets/workflow_binding_editor.dart';

void main() {
  final graph = <String, dynamic>{
    '1': {
      'class_type': 'CLIPTextEncode',
      'inputs': {
        'text': 'a cat',
        'clip': ['0', 0],
      },
    },
    '2': {
      'class_type': 'KSampler',
      'inputs': {'seed': 42, 'steps': 20},
    },
  };

  testWidgets('renders one row per literal input, grouped by node', (
    tester,
  ) async {
    await _openEditor(tester, graph: graph);

    expect(find.text('CLIPTextEncode (#1)'), findsOneWidget);
    expect(find.text('KSampler (#2)'), findsOneWidget);
    expect(find.byKey(const Key('binding-row-1-text-value')), findsOneWidget);
    expect(find.byKey(const Key('binding-row-2-seed-value')), findsOneWidget);
    expect(
      find.byKey(const Key('binding-row-2-steps-value')),
      findsOneWidget,
    );
  });

  testWidgets('a connection-valued input produces no row', (tester) async {
    await _openEditor(tester, graph: graph);

    expect(find.byKey(const Key('binding-row-1-clip-value')), findsNothing);
  });

  testWidgets('editing a value and saving reflects the edit in the graph', (
    tester,
  ) async {
    final read = await _openEditor(tester, graph: graph);

    await tester.enterText(
      find.byKey(const Key('binding-row-1-text-value')),
      'a dog',
    );
    await tester.tap(find.byKey(const Key('binding-editor-save')));
    await tester.pumpAndSettle();

    final result = read();
    expect(result, isNotNull);
    expect(result!.graph['1']['inputs']['text'], 'a dog');
    expect(result.bindings, isEmpty);
  });

  testWidgets(
    'toggling expose reveals binding fields and includes the row in the '
    'saved bindings',
    (tester) async {
      final read = await _openEditor(tester, graph: graph);

      expect(
        find.byKey(const Key('binding-row-1-text-label')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('binding-row-1-text-expose')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('binding-row-1-text-label')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('binding-editor-save')));
      await tester.pumpAndSettle();

      final result = read()!;
      expect(result.bindings, hasLength(1));
      expect(result.bindings.single.nodeId, '1');
      expect(result.bindings.single.inputName, 'text');
    },
  );

  testWidgets(
    'toggling expose back off hides the fields and excludes the row',
    (tester) async {
      final read = await _openEditor(tester, graph: graph);

      await tester.tap(find.byKey(const Key('binding-row-1-text-expose')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('binding-row-1-text-expose')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('binding-row-1-text-label')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('binding-editor-save')));
      await tester.pumpAndSettle();

      expect(read()!.bindings, isEmpty);
    },
  );

  testWidgets(
    'search narrows visible rows and clearing it restores prior collapse '
    'state',
    (tester) async {
      await _openEditor(tester, graph: graph);

      // Collapse node 1's group.
      await tester.tap(find.byKey(const Key('binding-group-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('binding-row-1-text-value')), findsNothing);

      // '1' matches node 1 by id, forcing its group open despite being
      // collapsed, while node 2 (no '1' anywhere in id/class/input names)
      // drops out of the list entirely.
      await tester.enterText(
        find.byKey(const Key('binding-editor-search')),
        '1',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('binding-row-1-text-value')),
        findsOneWidget,
      );
      expect(find.text('KSampler (#2)'), findsNothing);

      // Clearing the search restores the collapsed state.
      await tester.enterText(
        find.byKey(const Key('binding-editor-search')),
        '',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('binding-row-1-text-value')), findsNothing);
      expect(find.text('KSampler (#2)'), findsOneWidget);
    },
  );

  testWidgets('collapsing one group only affects that group\'s rows', (
    tester,
  ) async {
    await _openEditor(tester, graph: graph);

    await tester.tap(find.byKey(const Key('binding-group-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('binding-row-1-text-value')), findsNothing);
    expect(find.byKey(const Key('binding-row-2-seed-value')), findsOneWidget);
  });

  testWidgets('a required-and-empty exposed value blocks Save', (
    tester,
  ) async {
    await _openEditor(tester, graph: graph);

    await tester.tap(find.byKey(const Key('binding-row-2-seed-expose')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('binding-row-2-seed-required')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('binding-row-2-seed-value')),
      '',
    );
    await tester.pumpAndSettle();

    final saveButton = tester.widget<TextButton>(
      find.byKey(const Key('binding-editor-save')),
    );
    expect(saveButton.onPressed, isNull);
  });

  testWidgets('min greater than max blocks Save', (tester) async {
    await _openEditor(tester, graph: graph);

    await tester.tap(find.byKey(const Key('binding-row-2-seed-expose')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('binding-row-2-seed-min')),
      '10',
    );
    await tester.enterText(
      find.byKey(const Key('binding-row-2-seed-max')),
      '5',
    );
    await tester.pumpAndSettle();

    final saveButton = tester.widget<TextButton>(
      find.byKey(const Key('binding-editor-save')),
    );
    expect(saveButton.onPressed, isNull);
  });

  testWidgets('an enumeration control with no choices blocks Save', (
    tester,
  ) async {
    await _openEditor(tester, graph: graph);

    await tester.tap(find.byKey(const Key('binding-row-1-text-expose')));
    await tester.pumpAndSettle();
    await _selectDropdown(
      tester,
      key: const Key('binding-row-1-text-controlType'),
      label: 'enumeration',
    );

    final saveButton = tester.widget<TextButton>(
      find.byKey(const Key('binding-editor-save')),
    );
    expect(saveButton.onPressed, isNull);

    await tester.enterText(
      find.byKey(const Key('binding-row-1-text-choices')),
      'a, b',
    );
    await tester.pumpAndSettle();
    final enabled = tester.widget<TextButton>(
      find.byKey(const Key('binding-editor-save')),
    );
    expect(enabled.onPressed, isNotNull);
  });

  testWidgets('showNameAndKind true renders the name field and kind picker', (
    tester,
  ) async {
    await _openEditor(
      tester,
      graph: graph,
      showNameAndKind: true,
      initialName: 'my-workflow.json',
    );

    expect(find.byKey(const Key('binding-editor-name')), findsOneWidget);
    expect(find.byType(SegmentedButton<ComfyMediaKind>), findsOneWidget);
  });

  testWidgets('showNameAndKind false omits the name field and kind picker', (
    tester,
  ) async {
    await _openEditor(tester, graph: graph);

    expect(find.byKey(const Key('binding-editor-name')), findsNothing);
    expect(find.byType(SegmentedButton<ComfyMediaKind>), findsNothing);
  });

  testWidgets(
    'a row matching an initial binding starts exposed with that binding\'s '
    'settings',
    (tester) async {
      await _openEditor(
        tester,
        graph: graph,
        initialBindings: const [
          WorkflowInputBinding(
            id: 'b1',
            nodeId: '1',
            inputName: 'text',
            label: 'Prompt',
            role: BindingRole.prompt,
            controlType: WorkflowControlType.multiline,
            required: true,
          ),
        ],
      );

      expect(
        find.byKey(const Key('binding-row-1-text-label')),
        findsOneWidget,
      );
      final labelField = tester.widget<TextField>(
        find.byKey(const Key('binding-row-1-text-label')),
      );
      expect(labelField.controller!.text, 'Prompt');
    },
  );

  testWidgets('Cancel discards local edits and returns null', (
    tester,
  ) async {
    final read = await _openEditor(tester, graph: graph);

    await tester.enterText(
      find.byKey(const Key('binding-row-1-text-value')),
      'a dog',
    );
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(read(), isNull);
  });
}

typedef _ResultReader = WorkflowBindingEditorResult? Function();

Future<_ResultReader> _openEditor(
  WidgetTester tester, {
  required Map<String, dynamic> graph,
  List<WorkflowInputBinding> initialBindings = const [],
  bool showNameAndKind = false,
  String? initialName,
  ComfyMediaKind? initialKind,
}) async {
  // An exposed row's full field set (label, role/control dropdowns,
  // required, min/max) can push well past the default 800x600 test surface
  // -- grow it so every row's controls are actually hit-testable without
  // needing per-test scroll gymnastics.
  final originalSize = tester.view.physicalSize;
  final originalRatio = tester.view.devicePixelRatio;
  tester.view.physicalSize = const Size(800, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.physicalSize = originalSize;
    tester.view.devicePixelRatio = originalRatio;
  });

  WorkflowBindingEditorResult? result;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            result = await Navigator.of(context)
                .push<WorkflowBindingEditorResult>(
                  MaterialPageRoute(
                    builder: (_) => WorkflowBindingEditorScreen(
                      graph: graph,
                      initialBindings: initialBindings,
                      title: 'Test editor',
                      showNameAndKind: showNameAndKind,
                      initialName: initialName,
                      initialKind: initialKind,
                    ),
                  ),
                );
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return () => result;
}

/// Opens a [DropdownButtonFormField] by [key] and selects the item labeled
/// [label]. The overlay adds a second `Text` with the same string on top of
/// the closed field's current-selection text, so `.last` targets the menu
/// item rather than the field itself.
Future<void> _selectDropdown(
  WidgetTester tester, {
  required Key key,
  required String label,
}) async {
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}
