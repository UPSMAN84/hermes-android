import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';
import 'package:hermes_android/core/services/comfy_workflow_codec.dart';

void main() {
  group('workflow import', () {
    test('retains byte-exact source and hashes the original bytes', () {
      final source = utf8.encode('{"1":{"class_type":"X","inputs":{}}}');

      final imported = ComfyWorkflowCodec.decode(
        source,
        sourceFileName: 'workflow.json',
      );

      expect(imported.sourceBytes, source);
      expect(
        imported.sourceHash,
        '91ecf0444204d7c33517810937dc246f4fd8a897073c689216c6e7ae7856b8c0',
      );
      expect(imported.sourceFileName, 'workflow.json');
    });

    test('rejects input above the five MiB ceiling before decoding', () {
      final oversized = Uint8List(5 * 1024 * 1024 + 1);

      expect(
        () =>
            ComfyWorkflowCodec.decode(oversized, sourceFileName: 'large.json'),
        throwsFormatException,
      );
    });

    test('requires an API workflow map with valid node shapes', () {
      for (final source in [
        '[]',
        '{"1":{"inputs":{}}}',
        '{"1":{"class_type":"X"}}',
        '{"1":{"class_type":7,"inputs":{}}}',
        '{"1":{"class_type":"X","inputs":[]}}',
      ]) {
        expect(
          () => ComfyWorkflowCodec.decode(
            utf8.encode(source),
            sourceFileName: 'invalid.json',
          ),
          throwsFormatException,
          reason: source,
        );
      }
    });

    test('invalid raw draft cannot replace the last valid graph', () {
      final saved = ComfyWorkflowCodec.decode(
        utf8.encode('{"1":{"class_type":"X","inputs":{}}}'),
        sourceFileName: 'saved.json',
      ).graph;

      expect(
        () => ComfyWorkflowCodec.decode(
          utf8.encode('{"1":{"class_type":"X"}}'),
          sourceFileName: 'draft.json',
        ),
        throwsFormatException,
      );
      expect(saved, {
        '1': {'class_type': 'X', 'inputs': <String, dynamic>{}},
      });
    });
  });

  group('bindings', () {
    test('binding mutates only a deep copy and preserves unknown fields', () {
      final imported = ComfyWorkflowCodec.decode(
        utf8.encode(
          '{"6":{"class_type":"CustomText","inputs":{"text":"old","opaque":{"x":1}}},"_meta":{"v":9}}',
        ),
        sourceFileName: 'workflow.json',
      );
      final binding = WorkflowInputBinding(
        id: 'prompt',
        nodeId: '6',
        inputName: 'text',
        label: 'Prompt',
        role: BindingRole.prompt,
        controlType: WorkflowControlType.multiline,
        required: true,
      );

      final runGraph = ComfyWorkflowCodec.applyBindings(
        imported.graph,
        [binding],
        {'prompt': 'new'},
      );

      expect(runGraph['6']['inputs']['text'], 'new');
      expect(imported.graph['6']['inputs']['text'], 'old');
      expect(runGraph['6']['inputs']['opaque'], {'x': 1});
      expect(runGraph['_meta'], {'v': 9});
    });

    test('verifies every target before assigning any values', () {
      final graph = <String, dynamic>{
        '1': {
          'class_type': 'X',
          'inputs': {'text': 'old'},
        },
      };
      final bindings = [
        fixtureBinding(),
        WorkflowInputBinding(
          id: 'missing',
          nodeId: '2',
          inputName: 'value',
          label: 'Missing',
          role: BindingRole.custom,
          controlType: WorkflowControlType.text,
          required: true,
        ),
      ];

      expect(
        () => ComfyWorkflowCodec.applyBindings(graph, bindings, {
          'prompt': 'new',
          'missing': 'value',
        }),
        throwsStateError,
      );
      expect(graph['1']['inputs']['text'], 'old');
    });

    test('edited graph export preserves unknown fields and no sidecar data', () {
      final imported = ComfyWorkflowCodec.decode(
        utf8.encode(
          '{"1":{"class_type":"X","inputs":{"text":"old"},"unknown":17},"_meta":{"v":9}}',
        ),
        sourceFileName: 'workflow.json',
      );
      final edited = ComfyWorkflowCodec.applyBindings(
        imported.graph,
        [fixtureBinding()],
        {'prompt': 'new'},
      );
      final exported = jsonDecode(jsonEncode(edited)) as Map<String, dynamic>;

      expect(exported['1']['unknown'], 17);
      expect(exported['_meta'], {'v': 9});
      expect(exported['1']['inputs']['text'], 'new');
      expect(jsonEncode(exported), isNot(contains('"bindings"')));
    });
  });

  group('model JSON', () {
    test('workflow definition and bindings round trip', () {
      final definition = fixtureDefinition(
        validation: const WorkflowValidationResult(
          issues: [
            WorkflowValidationIssue(
              code: 'notice',
              message: 'Checked',
              blocking: false,
            ),
          ],
          fingerprint: 'fingerprint',
          endpoint: 'http://host:8188',
        ),
      );

      final restored = ComfyWorkflowDefinition.fromJson(definition.toJson());

      expect(restored.toJson(), definition.toJson());
      expect(restored.bindings.single.choices, ['a', 'b']);
      expect(restored.validation!.isValid, isTrue);
    });
  });

  group('local validation', () {
    test('reports missing binding nodes and inputs', () {
      final result = ComfyWorkflowCodec.validateLocal(
        graph: {
          '1': {
            'class_type': 'X',
            'inputs': {'text': 'old'},
          },
        },
        bindings: [
          fixtureBinding(nodeId: '2'),
          fixtureBinding(id: 'other', inputName: 'missing'),
        ],
      );

      expect(result.issues.map((issue) => issue.code), [
        'missing_node',
        'missing_input',
      ]);
      expect(result.isValid, isFalse);
    });
  });

  group('object info validation', () {
    test('object info reports missing classes and mapped inputs', () {
      final result = ComfyWorkflowCodec.validateObjectInfo(
        definition: fixtureDefinition(
          graph: {
            '6': {
              'class_type': 'Known',
              'inputs': {'text': 'hello'},
            },
            '7': {'class_type': 'Missing', 'inputs': <String, dynamic>{}},
          },
          bindings: [fixtureBinding(nodeId: '6', inputName: 'absent')],
        ),
        endpoint: ComfyEndpoint.parse('http://host:8188'),
        objectInfo: {
          'Known': {
            'input': {
              'required': {
                'text': ['STRING', <String, dynamic>{}],
              },
            },
          },
        },
      );

      expect(
        result.issues.map((e) => e.code),
        containsAll(['missing_class', 'missing_input']),
      );
    });

    test(
      'blocks only schema-exposed primitive range enum and model errors',
      () {
        final result = ComfyWorkflowCodec.validateObjectInfo(
          definition: fixtureDefinition(
            graph: {
              '1': {
                'class_type': 'Sampler',
                'inputs': {
                  'steps': 0,
                  'cfg': 'high',
                  'mode': 'invalid',
                  'model_name': 'missing.safetensors',
                  'dynamic_model': 'server/may/accept/this.safetensors',
                  'linked': ['2', 0],
                },
              },
            },
            bindings: [
              fixtureBinding(
                inputName: 'steps',
                role: BindingRole.steps,
                controlType: WorkflowControlType.integer,
              ),
              fixtureBinding(
                id: 'cfg',
                inputName: 'cfg',
                role: BindingRole.cfg,
                controlType: WorkflowControlType.decimal,
              ),
              fixtureBinding(
                id: 'mode',
                inputName: 'mode',
                role: BindingRole.custom,
                controlType: WorkflowControlType.enumeration,
              ),
            ],
          ),
          endpoint: ComfyEndpoint.parse('http://host:8188'),
          objectInfo: {
            'Sampler': {
              'input': {
                'required': {
                  'steps': [
                    'INT',
                    {'min': 1, 'max': 100},
                  ],
                  'cfg': ['FLOAT', <String, dynamic>{}],
                  'mode': [
                    ['fast', 'quality'],
                    <String, dynamic>{},
                  ],
                  'model_name': [
                    ['present.safetensors'],
                    <String, dynamic>{},
                  ],
                  'dynamic_model': ['STRING', <String, dynamic>{}],
                  'linked': ['MODEL', <String, dynamic>{}],
                },
              },
            },
          },
        );

        expect(
          result.issues.map((issue) => issue.code),
          contains('out_of_range'),
        );
        expect(
          result.issues.map((issue) => issue.code),
          contains('type_mismatch'),
        );
        expect(
          result.issues.map((issue) => issue.code),
          contains('enum_mismatch'),
        );
        expect(
          result.issues.map((issue) => issue.code),
          contains('missing_model'),
        );
        expect(
          result.issues.where((issue) => issue.inputName == 'dynamic_model'),
          isEmpty,
        );
        expect(
          result.issues.where((issue) => issue.inputName == 'linked'),
          isEmpty,
        );
      },
    );

    test('endpoint and object-info changes invalidate the fingerprint', () {
      final definition = fixtureDefinition();
      final first = ComfyWorkflowCodec.validateObjectInfo(
        definition: definition,
        endpoint: ComfyEndpoint.parse('http://host:8188/'),
        objectInfo: validObjectInfo(extra: {'z': 1, 'a': 2}),
      );
      final sameCanonicalData = ComfyWorkflowCodec.validateObjectInfo(
        definition: definition,
        endpoint: ComfyEndpoint.parse('http://host:8188'),
        objectInfo: validObjectInfo(extra: {'a': 2, 'z': 1}),
      );
      final changedEndpoint = ComfyWorkflowCodec.validateObjectInfo(
        definition: definition,
        endpoint: ComfyEndpoint.parse('http://other:8188'),
        objectInfo: validObjectInfo(extra: {'a': 2, 'z': 1}),
      );
      final changedSchema = ComfyWorkflowCodec.validateObjectInfo(
        definition: definition,
        endpoint: ComfyEndpoint.parse('http://host:8188'),
        objectInfo: validObjectInfo(extra: {'a': 3, 'z': 1}),
      );

      expect(first.fingerprint, sameCanonicalData.fingerprint);
      expect(changedEndpoint.fingerprint, isNot(first.fingerprint));
      expect(changedSchema.fingerprint, isNot(first.fingerprint));
    });
  });

  test('suggestions propose common fields without changing the graph', () {
    final graph = <String, dynamic>{
      '1': {
        'class_type': 'Common',
        'inputs': {
          'text': 'hello',
          'seed': 1,
          'width': 512,
          'height': 512,
          'steps': 20,
          'cfg': 7.5,
          'frames': 16,
          'fps': 8,
          'image': 'input.png',
          'other': true,
        },
      },
    };
    final before = jsonEncode(graph);

    final suggestions = ComfyWorkflowCodec.suggestBindings(graph);

    expect(suggestions.map((binding) => binding.inputName), [
      'text',
      'seed',
      'width',
      'height',
      'steps',
      'cfg',
      'frames',
      'fps',
      'image',
    ]);
    expect(jsonEncode(graph), before);
  });
}

WorkflowInputBinding fixtureBinding({
  String id = 'prompt',
  String nodeId = '1',
  String inputName = 'text',
  BindingRole role = BindingRole.prompt,
  WorkflowControlType controlType = WorkflowControlType.multiline,
}) => WorkflowInputBinding(
  id: id,
  nodeId: nodeId,
  inputName: inputName,
  label: 'Prompt',
  role: role,
  controlType: controlType,
  required: true,
  choices: const ['a', 'b'],
);

ComfyWorkflowDefinition fixtureDefinition({
  JsonObject? graph,
  List<WorkflowInputBinding>? bindings,
  WorkflowValidationResult? validation,
}) => ComfyWorkflowDefinition(
  id: 'workflow-1',
  name: 'Fixture',
  kind: ComfyMediaKind.image,
  workingGraph:
      graph ??
      {
        '1': {
          'class_type': 'Known',
          'inputs': {'text': 'hello'},
        },
      },
  sourceHash: 'source-hash',
  sourceFileName: 'workflow.json',
  bindings: bindings ?? [fixtureBinding()],
  createdAt: DateTime.utc(2026, 8, 20),
  updatedAt: DateTime.utc(2026, 8, 20, 1),
  validation: validation,
);

JsonObject validObjectInfo({required JsonObject extra}) => {
  'Known': {
    'input': {
      'required': {
        'text': ['STRING', extra],
      },
    },
  },
};
