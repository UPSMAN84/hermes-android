import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/comfy_ui_graph.dart';
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

    test('accepts ComfyUI\'s regular UI-format export (nodes/links)', () {
      final source = utf8.encode(
        jsonEncode({
          'last_node_id': 1,
          'last_link_id': 0,
          'nodes': [
            {
              'id': 1,
              'type': 'CheckpointLoaderSimple',
              'pos': [0, 0],
              'size': [300, 100],
              'mode': 0,
              'inputs': <dynamic>[],
              'outputs': <dynamic>[],
              'properties': <String, dynamic>{},
              'widgets_values': ['sd_xl_base_1.0.safetensors'],
            },
          ],
          'links': <dynamic>[],
          'groups': <dynamic>[],
          'config': <String, dynamic>{},
          'extra': <String, dynamic>{},
          'version': 0.4,
        }),
      );

      final imported = ComfyWorkflowCodec.decode(
        source,
        sourceFileName: 'ui-workflow.json',
      );

      expect(ComfyWorkflowCodec.shapeOf(imported.graph), ComfyGraphShape.uiFormat);
    });

    test('rejected raw draft returns the unchanged saved graph', () {
      final saved = ComfyWorkflowCodec.decode(
        utf8.encode(
          '{"1":{"class_type":"X","inputs":{"text":"saved"},"unknown":17}}',
        ),
        sourceFileName: 'saved.json',
      ).graph;

      final result = ComfyWorkflowCodec.applyDraft(
        savedGraph: saved,
        draftBytes: utf8.encode('{"1":{"class_type":"X"}}'),
      );

      expect(result.accepted, isFalse);
      expect(result.error, isNotNull);
      expect(identical(result.graph, saved), isTrue);
      expect(saved, {
        '1': {
          'class_type': 'X',
          'inputs': {'text': 'saved'},
          'unknown': 17,
        },
      });
    });

    test(
      'valid raw draft returns a replacement without mutating saved graph',
      () {
        final saved = ComfyWorkflowCodec.decode(
          utf8.encode('{"1":{"class_type":"X","inputs":{"text":"saved"}}}'),
          sourceFileName: 'saved.json',
        ).graph;

        final result = ComfyWorkflowCodec.applyDraft(
          savedGraph: saved,
          draftBytes: utf8.encode(
            '{"1":{"class_type":"X","inputs":{"text":"draft"},"unknown":9}}',
          ),
        );

        expect(result.accepted, isTrue);
        expect(result.error, isNull);
        expect(identical(result.graph, saved), isFalse);
        expect(result.graph['1']['inputs']['text'], 'draft');
        expect(result.graph['1']['unknown'], 9);
        expect(saved['1']['inputs']['text'], 'saved');
      },
    );
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

    test(
      'legitimate bindings field survives while Hermes bindings stay separate',
      () {
        final imported = ComfyWorkflowCodec.decode(
          utf8.encode(
            '{"1":{"class_type":"X","inputs":{"text":"old"},"bindings":{"custom":true},"unknown":17},"_meta":{"v":9}}',
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
        expect(exported['1']['bindings'], {'custom': true});

        final definition = fixtureDefinition(
          graph: edited,
          bindings: [fixtureBinding()],
        );
        expect(definition.workingGraph['1']['bindings'], {'custom': true});
        expect(definition.bindings.single.id, 'prompt');
      },
    );
  });

  group('inline value editing', () {
    test('updateFlatGraphInput mutates only a deep copy', () {
      final graph = <String, dynamic>{
        '1': {
          'class_type': 'X',
          'inputs': {'text': 'old'},
        },
      };

      final updated = ComfyWorkflowCodec.updateFlatGraphInput(
        graph: graph,
        nodeId: '1',
        inputName: 'text',
        value: 'new',
      );

      expect(updated['1']['inputs']['text'], 'new');
      expect(graph['1']['inputs']['text'], 'old');
    });

    test('updateFlatGraphInput rejects an unknown node or input', () {
      final graph = <String, dynamic>{
        '1': {
          'class_type': 'X',
          'inputs': {'text': 'old'},
        },
      };
      expect(
        () => ComfyWorkflowCodec.updateFlatGraphInput(
          graph: graph,
          nodeId: '2',
          inputName: 'text',
          value: 'new',
        ),
        throwsStateError,
      );
      expect(
        () => ComfyWorkflowCodec.updateFlatGraphInput(
          graph: graph,
          nodeId: '1',
          inputName: 'missing',
          value: 'new',
        ),
        throwsStateError,
      );
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

    test('schema-enumerated common model inputs report missing choices', () {
      for (final inputName in [
        'model_name',
        'checkpoint_name',
        'ckpt_name',
        'unet_name',
        'clip_name',
        'clip_name1',
        'clip_name2',
        'clip_name3',
        'control_net_name',
        'controlnet_name',
        'lora_name',
        'vae_name',
      ]) {
        final result = ComfyWorkflowCodec.validateObjectInfo(
          definition: fixtureDefinition(
            graph: {
              '1': {
                'class_type': 'Loader',
                'inputs': {inputName: 'missing.safetensors'},
              },
            },
            bindings: const [],
          ),
          endpoint: ComfyEndpoint.parse('http://host:8188'),
          objectInfo: {
            'Loader': {
              'input': {
                'required': {
                  inputName: [
                    ['present.safetensors'],
                    <String, dynamic>{},
                  ],
                },
              },
            },
          },
        );

        expect(
          result.issues
              .where(
                (issue) =>
                    issue.code == 'missing_model' &&
                    issue.inputName == inputName,
              )
              .length,
          1,
          reason: inputName,
        );
      }
    });

    test('non-selector enums use enum mismatch, not missing model', () {
      for (final inputName in [
        'model_type',
        'checkpoint_mode',
        'ckpt_mode',
        'unet_mode',
        'clip_mode',
        'control_net_mode',
        'controlnet_mode',
        'lora_mode',
        'vae_mode',
      ]) {
        final result = ComfyWorkflowCodec.validateObjectInfo(
          definition: fixtureDefinition(
            graph: {
              '1': {
                'class_type': 'ConfigNode',
                'inputs': {inputName: 'unsupported'},
              },
            },
            bindings: [
              fixtureBinding(
                id: inputName,
                inputName: inputName,
                role: BindingRole.custom,
                controlType: WorkflowControlType.enumeration,
              ),
            ],
          ),
          endpoint: ComfyEndpoint.parse('http://host:8188'),
          objectInfo: {
            'ConfigNode': {
              'input': {
                'required': {
                  inputName: [
                    ['supported'],
                    <String, dynamic>{},
                  ],
                },
              },
            },
          },
        );

        expect(
          result.issues
              .where(
                (issue) =>
                    issue.code == 'enum_mismatch' &&
                    issue.inputName == inputName,
              )
              .length,
          1,
          reason: inputName,
        );
        expect(
          result.issues.where((issue) => issue.code == 'missing_model'),
          isEmpty,
          reason: inputName,
        );
      }
    });

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

  test('suggestions skip inputs wired to another node', () {
    final graph = <String, dynamic>{
      '1': {
        'class_type': 'Common',
        'inputs': {
          'text': 'hello',
          'width': ['2', 0],
          'height': 512,
        },
      },
    };

    final suggestions = ComfyWorkflowCodec.suggestBindings(graph);

    expect(suggestions.map((binding) => binding.inputName), [
      'text',
      'height',
    ]);
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
