import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/comfy_ui_graph.dart';
import 'package:hermes_android/core/services/comfy_ui_graph_converter.dart';

const _kSamplerSchema = {
  'input': {
    'required': {
      'model': ['MODEL'],
      'positive': ['CONDITIONING'],
      'negative': ['CONDITIONING'],
      'latent_image': ['LATENT'],
      'seed': [
        'INT',
        {'default': 0, 'min': 0, 'max': 999999, 'control_after_generate': true},
      ],
      'steps': [
        'INT',
        {'default': 20, 'min': 1, 'max': 10000},
      ],
      'cfg': [
        'FLOAT',
        {'default': 8.0, 'min': 0.0, 'max': 100.0},
      ],
      'sampler_name': [
        ['euler', 'ddim', 'euler_ancestral'],
      ],
      'scheduler': [
        ['normal', 'simple'],
      ],
      'denoise': [
        'FLOAT',
        {'default': 1.0, 'min': 0.0, 'max': 1.0},
      ],
    },
  },
};

Map<String, dynamic> _objectInfo({Map<String, dynamic>? extra}) => {
  'KSampler': _kSamplerSchema,
  'CheckpointLoaderSimple': {
    'input': {
      'required': {
        'ckpt_name': [
          ['model.safetensors'],
        ],
      },
    },
  },
  ...?extra,
};

UiGraphNode _samplerNode({
  int id = 2,
  List<Object?>? widgetsValues,
  Map<String, Object?>? widgetsValuesNamed,
  int mode = 0,
  String type = 'KSampler',
  Map<String, Object?> properties = const {},
  List<UiGraphSocket>? inputs,
}) => UiGraphNode(
  id: id,
  type: type,
  pos: (0, 0),
  size: (0, 0),
  mode: mode,
  inputs:
      inputs ??
      const [
        UiGraphSocket(name: 'model', type: 'MODEL', link: 1),
        UiGraphSocket(name: 'positive', type: 'CONDITIONING', link: 2),
        UiGraphSocket(name: 'negative', type: 'CONDITIONING', link: 3),
        UiGraphSocket(name: 'latent_image', type: 'LATENT', link: 4),
      ],
  outputs: const [],
  widgetsValues: widgetsValues ?? const [12345, 'randomize', 20, 8.0, 'euler', 'normal', 1.0],
  widgetsValuesNamed: widgetsValuesNamed,
  properties: properties,
);

UiGraphNode _loaderNode({int id = 1, int mode = 0}) => UiGraphNode(
  id: id,
  type: 'CheckpointLoaderSimple',
  pos: (0, 0),
  size: (0, 0),
  mode: mode,
  inputs: const [],
  outputs: const [
    UiGraphSocket(name: 'MODEL', type: 'MODEL'),
    UiGraphSocket(name: 'CONDITIONING', type: 'CONDITIONING'),
    UiGraphSocket(name: 'CONDITIONING2', type: 'CONDITIONING'),
    UiGraphSocket(name: 'LATENT', type: 'LATENT'),
  ],
  widgetsValues: const ['model.safetensors'],
  properties: const {},
);

UiFormatGraph _graph({
  required List<UiGraphNode> nodes,
  List<UiGraphLink>? links,
}) => UiFormatGraph(
  nodes: nodes,
  links:
      links ??
      const [
        UiGraphLink(
          id: 1,
          originNodeId: 1,
          originSlot: 0,
          targetNodeId: 2,
          targetSlot: 0,
          type: 'MODEL',
        ),
        UiGraphLink(
          id: 2,
          originNodeId: 1,
          originSlot: 1,
          targetNodeId: 2,
          targetSlot: 1,
          type: 'CONDITIONING',
        ),
        UiGraphLink(
          id: 3,
          originNodeId: 1,
          originSlot: 2,
          targetNodeId: 2,
          targetSlot: 2,
          type: 'CONDITIONING',
        ),
        UiGraphLink(
          id: 4,
          originNodeId: 1,
          originSlot: 3,
          targetNodeId: 2,
          targetSlot: 3,
          type: 'LATENT',
        ),
      ],
);

void main() {
  group('positional resolution', () {
    test(
      'resolves sockets via links and widgets via position, '
      'skipping the synthetic control_after_generate slot',
      () {
        final result = ComfyUiGraphConverter.convert(
          graph: _graph(nodes: [_loaderNode(), _samplerNode()]),
          objectInfo: _objectInfo(),
        );

        expect(result, isA<ConvertedPrompt>());
        final prompt = (result as ConvertedPrompt).prompt;
        final ksamplerInputs = (prompt['2'] as Map)['inputs'] as Map;
        expect(ksamplerInputs['model'], ['1', 0]);
        expect(ksamplerInputs['positive'], ['1', 1]);
        expect(ksamplerInputs['negative'], ['1', 2]);
        expect(ksamplerInputs['latent_image'], ['1', 3]);
        expect(ksamplerInputs['seed'], 12345);
        expect(ksamplerInputs['steps'], 20);
        expect(ksamplerInputs['cfg'], 8.0);
        expect(ksamplerInputs['sampler_name'], 'euler');
        expect(ksamplerInputs['scheduler'], 'normal');
        expect(ksamplerInputs['denoise'], 1.0);
        expect(ksamplerInputs.containsKey('control_after_generate'), isFalse);
      },
    );

    test('prefers widgets_values_named over positional values when present', () {
      // Deliberately wrong positional array -- if the converter used it,
      // every value below would come out shifted/incorrect.
      final result = ComfyUiGraphConverter.convert(
        graph: _graph(
          nodes: [
            _loaderNode(),
            _samplerNode(
              widgetsValues: const [999, 999, 999, 999, 999, 999, 999],
              widgetsValuesNamed: const {
                'seed': 1,
                'control_after_generate': 'fixed',
                'steps': 2,
                'cfg': 3.0,
                'sampler_name': 'ddim',
                'scheduler': 'simple',
                'denoise': 0.5,
              },
            ),
          ],
        ),
        objectInfo: _objectInfo(),
      );

      final prompt = (result as ConvertedPrompt).prompt;
      final inputs = (prompt['2'] as Map)['inputs'] as Map;
      expect(inputs['seed'], 1);
      expect(inputs['steps'], 2);
      expect(inputs['cfg'], 3.0);
      expect(inputs['denoise'], 0.5);
    });

    test(
      'an override still consumes its positional slot so later widgets stay aligned',
      () {
        final result = ComfyUiGraphConverter.convert(
          graph: _graph(nodes: [_loaderNode(), _samplerNode()]),
          objectInfo: _objectInfo(),
          overrides: const {('2', 'steps'): 999},
        );

        final prompt = (result as ConvertedPrompt).prompt;
        final inputs = (prompt['2'] as Map)['inputs'] as Map;
        expect(inputs['steps'], 999);
        expect(inputs['cfg'], 8.0); // would be 'euler' if the index had drifted
        expect(inputs['sampler_name'], 'euler');
      },
    );

    test('a live-linked hard socket never consumes a widgets_values slot', () {
      // Sanity: exactly 7 widget values for 6 widget-capable inputs (with the
      // control_after_generate companion) even though 4 more inputs are
      // hard sockets resolved via links -- proves sockets never touch the
      // positional index.
      final result = ComfyUiGraphConverter.convert(
        graph: _graph(nodes: [_loaderNode(), _samplerNode()]),
        objectInfo: _objectInfo(),
      );
      expect(result, isA<ConvertedPrompt>());
    });
  });

  group('class resolution', () {
    test('falls back to Node name for S&R when the raw type is unrecognized', () {
      final result = ComfyUiGraphConverter.convert(
        graph: _graph(
          nodes: [
            _loaderNode(),
            _samplerNode(
              type: 'SomeRenamedKSampler',
              properties: const {'Node name for S&R': 'KSampler'},
            ),
          ],
        ),
        objectInfo: _objectInfo(),
      );

      expect(result, isA<ConvertedPrompt>());
      final prompt = (result as ConvertedPrompt).prompt;
      expect((prompt['2'] as Map)['class_type'], 'KSampler');
    });
  });

  group('mode handling', () {
    test('a muted node is excluded and dependents get missing_link', () {
      final result = ComfyUiGraphConverter.convert(
        graph: _graph(nodes: [_loaderNode(mode: 2), _samplerNode()]),
        objectInfo: _objectInfo(),
      );
      expect(result, isA<ConversionFailed>());
      final failed = result as ConversionFailed;
      expect(failed.issues.any((i) => i.code == 'missing_link'), isTrue);
    });

    test(
      'a bypassed node with no outgoing links is skipped silently',
      () {
        final result = ComfyUiGraphConverter.convert(
          graph: UiFormatGraph(
            nodes: [_loaderNode(), _samplerNode(mode: 4)],
            links: const [],
          ),
          objectInfo: _objectInfo(),
        );
        // The bypassed sampler has no links at all, so nothing depends on
        // it -- it should vanish without complaint.
        expect(result, isA<ConvertedPrompt>());
        final prompt = (result as ConvertedPrompt).prompt;
        expect(prompt.containsKey('2'), isFalse);
      },
    );

    test(
      'a bypassed node with active downstream connections is refused',
      () {
        final result = ComfyUiGraphConverter.convert(
          graph: _graph(nodes: [_loaderNode(mode: 4), _samplerNode()]),
          objectInfo: _objectInfo(),
        );
        expect(result, isA<ConversionFailed>());
        final failed = result as ConversionFailed;
        expect(failed.issues.any((i) => i.code == 'unsupported_bypass'), isTrue);
      },
    );
  });

  group('missing classes', () {
    test(
      'any node with no matching class is a missing_class issue, referenced '
      'or not -- a leaf/sink node (e.g. SaveImage-style, no outputs) is '
      'never distinguishable from a decorative one by graph shape alone, so '
      'nothing is silently dropped',
      () {
        final annotation = UiGraphNode(
          id: 99,
          type: 'MarkdownNote',
          pos: (0, 0),
          size: (0, 0),
          mode: 0,
          inputs: const [],
          outputs: const [],
          widgetsValues: const ['# notes'],
          properties: const {},
        );
        final result = ComfyUiGraphConverter.convert(
          graph: _graph(nodes: [_loaderNode(), _samplerNode(), annotation]),
          objectInfo: _objectInfo(),
        );
        expect(result, isA<ConversionFailed>());
        final failed = result as ConversionFailed;
        expect(
          failed.issues.any(
            (i) => i.code == 'missing_class' && i.nodeId == '99',
          ),
          isTrue,
        );
      },
    );

    test('a referenced node with no matching class is a missing_class issue', () {
      final result = ComfyUiGraphConverter.convert(
        graph: _graph(nodes: [_loaderNode(), _samplerNode()]),
        objectInfo: _objectInfo()..remove('CheckpointLoaderSimple'),
      );
      expect(result, isA<ConversionFailed>());
      final failed = result as ConversionFailed;
      expect(failed.issues.any((i) => i.code == 'missing_class'), isTrue);
    });
  });

  group('reconverted widgets', () {
    test(
      'a widget-marked input with no live link falls back to its widget value',
      () {
        final result = ComfyUiGraphConverter.convert(
          graph: _graph(
            nodes: [
              _loaderNode(),
              _samplerNode(
                inputs: const [
                  UiGraphSocket(name: 'model', type: 'MODEL', link: 1),
                  UiGraphSocket(name: 'positive', type: 'CONDITIONING', link: 2),
                  UiGraphSocket(name: 'negative', type: 'CONDITIONING', link: 3),
                  UiGraphSocket(name: 'latent_image', type: 'LATENT', link: 4),
                  UiGraphSocket(
                    name: 'steps',
                    type: 'INT',
                    link: null,
                    hasWidgetMarker: true,
                  ),
                ],
              ),
            ],
          ),
          objectInfo: _objectInfo(),
        );

        expect(result, isA<ConvertedPrompt>());
        final prompt = (result as ConvertedPrompt).prompt;
        final inputs = (prompt['2'] as Map)['inputs'] as Map;
        expect(inputs['steps'], 20); // pulled from widgets_values, not flagged
      },
    );

    test('an unlinked hard socket with no widget marker is missing_link', () {
      final result = ComfyUiGraphConverter.convert(
        graph: _graph(
          nodes: [
            _loaderNode(),
            _samplerNode(
              inputs: const [
                UiGraphSocket(name: 'model', type: 'MODEL', link: null),
                UiGraphSocket(name: 'positive', type: 'CONDITIONING', link: 2),
                UiGraphSocket(name: 'negative', type: 'CONDITIONING', link: 3),
                UiGraphSocket(name: 'latent_image', type: 'LATENT', link: 4),
              ],
            ),
          ],
        ),
        objectInfo: _objectInfo(),
      );

      expect(result, isA<ConversionFailed>());
      final failed = result as ConversionFailed;
      expect(failed.issues.any((i) => i.code == 'missing_link' && i.inputName == 'model'), isTrue);
    });
  });

  group('custom scalar widget types', () {
    // Regression for a real failure: ResolutionSelector's `aspect_ratio`
    // input uses a custom, non-standard type name (not INT/FLOAT/STRING/
    // BOOLEAN/enum) for what is actually a widget with a real saved value,
    // not a hard socket. Misclassifying it produced "Required input
    // aspect_ratio ... is not connected" even though the file had a value.
    test(
      'an unrecognized custom scalar type resolves as a widget, not a '
      'required hard socket',
      () {
        final schema = {
          'ResolutionSelector': {
            'input': {
              'required': {
                'aspect_ratio': ['ASPECT_RATIO', <String, dynamic>{}],
              },
            },
          },
        };
        final node = UiGraphNode(
          id: 41,
          type: 'ResolutionSelector',
          pos: (0, 0),
          size: (0, 0),
          mode: 0,
          inputs: const [],
          outputs: const [],
          widgetsValues: const ['16:9'],
          properties: const {},
        );

        final result = ComfyUiGraphConverter.convert(
          graph: UiFormatGraph(nodes: [node], links: const []),
          objectInfo: schema,
        );

        expect(result, isA<ConvertedPrompt>());
        final prompt = (result as ConvertedPrompt).prompt;
        expect((prompt['41'] as Map)['inputs']['aspect_ratio'], '16:9');
      },
    );

    test('a known hard-socket type is still required to be connected', () {
      final schema = {
        'X': {
          'input': {
            'required': {
              'model': ['MODEL'],
            },
          },
        },
      };
      final node = UiGraphNode(
        id: 1,
        type: 'X',
        pos: (0, 0),
        size: (0, 0),
        mode: 0,
        inputs: const [],
        outputs: const [],
        widgetsValues: const [],
        properties: const {},
      );

      final result = ComfyUiGraphConverter.convert(
        graph: UiFormatGraph(nodes: [node], links: const []),
        objectInfo: schema,
      );

      expect(result, isA<ConversionFailed>());
    });
  });

  group('editor kind inference', () {
    List<SchemaInput> inputsFor(Map<String, dynamic> required) =>
        ComfyUiGraphConverter.orderedSchemaInputs({
          'input': {'required': required},
        });

    test('a multiline STRING is a multiline editor, a plain one is text', () {
      final inputs = inputsFor({
        'text': [
          'STRING',
          {'multiline': true},
        ],
        'name': ['STRING', <String, dynamic>{}],
      });
      expect(
        inputs.firstWhere((i) => i.name == 'text').editorKind,
        WidgetEditorKind.multiline,
      );
      expect(
        inputs.firstWhere((i) => i.name == 'name').editorKind,
        WidgetEditorKind.text,
      );
    });

    test('a plain-list enum is a dropdown with its choices', () {
      final inputs = inputsFor({
        'sampler_name': [
          ['euler', 'ddim'],
        ],
      });
      final input = inputs.single;
      expect(input.editorKind, WidgetEditorKind.dropdown);
      expect(input.choices, ['euler', 'ddim']);
    });

    test(
      'a custom scalar type with an explicit choices option is a dropdown',
      () {
        final inputs = inputsFor({
          'aspect_ratio': [
            'ASPECT_RATIO',
            {
              'choices': ['1:1', '16:9', '9:16'],
            },
          ],
        });
        final input = inputs.single;
        expect(input.editorKind, WidgetEditorKind.dropdown);
        expect(input.choices, ['1:1', '16:9', '9:16']);
      },
    );

    test(
      'a custom scalar type with no choices falls back to a text field',
      () {
        final inputs = inputsFor({
          'aspect_ratio': ['ASPECT_RATIO', <String, dynamic>{}],
        });
        expect(inputs.single.editorKind, WidgetEditorKind.text);
      },
    );

    test('INT/FLOAT/BOOLEAN map to their numeric/toggle editors', () {
      final inputs = inputsFor({
        'steps': ['INT', <String, dynamic>{}],
        'cfg': ['FLOAT', <String, dynamic>{}],
        'enabled': ['BOOLEAN', <String, dynamic>{}],
      });
      expect(
        inputs.firstWhere((i) => i.name == 'steps').editorKind,
        WidgetEditorKind.integer,
      );
      expect(
        inputs.firstWhere((i) => i.name == 'cfg').editorKind,
        WidgetEditorKind.decimal,
      );
      expect(
        inputs.firstWhere((i) => i.name == 'enabled').editorKind,
        WidgetEditorKind.toggle,
      );
    });
  });

  group('optional inputs', () {
    // Regression for a real failure: "D2 Size Selector"'s `images` input is
    // optional and legitimately unwired in a workflow that runs fine
    // directly in ComfyUI -- an earlier version treated every schema input
    // (required or optional) identically and failed conversion on it.
    test(
      'an unwired optional hard-socket input is omitted, not a failure',
      () {
        final schema = {
          'D2SizeSelector': {
            'input': {
              'required': {
                'width': ['INT', <String, dynamic>{}],
              },
              'optional': {
                'images': ['IMAGE'],
              },
            },
          },
        };
        final node = UiGraphNode(
          id: 35,
          type: 'D2SizeSelector',
          pos: (0, 0),
          size: (0, 0),
          mode: 0,
          inputs: const [],
          outputs: const [],
          widgetsValues: const [512],
          properties: const {},
        );

        final result = ComfyUiGraphConverter.convert(
          graph: UiFormatGraph(nodes: [node], links: const []),
          objectInfo: schema,
        );

        expect(result, isA<ConvertedPrompt>());
        final inputs = ((result as ConvertedPrompt).prompt['35'] as Map)['inputs']
            as Map;
        expect(inputs['width'], 512);
        expect(inputs.containsKey('images'), isFalse);
      },
    );

    test(
      'a required hard-socket input left unwired still fails conversion',
      () {
        final schema = {
          'D2SizeSelector': {
            'input': {
              'required': {
                'images': ['IMAGE'],
              },
            },
          },
        };
        final node = UiGraphNode(
          id: 35,
          type: 'D2SizeSelector',
          pos: (0, 0),
          size: (0, 0),
          mode: 0,
          inputs: const [],
          outputs: const [],
          widgetsValues: const [],
          properties: const {},
        );

        final result = ComfyUiGraphConverter.convert(
          graph: UiFormatGraph(nodes: [node], links: const []),
          objectInfo: schema,
        );

        expect(result, isA<ConversionFailed>());
      },
    );

    test(
      'an optional widget input with no available value is omitted, not a '
      'failure',
      () {
        final schema = {
          'X': {
            'input': {
              'required': {
                'width': ['INT', <String, dynamic>{}],
              },
              'optional': {
                'note': ['STRING', <String, dynamic>{}],
              },
            },
          },
        };
        final node = UiGraphNode(
          id: 1,
          type: 'X',
          pos: (0, 0),
          size: (0, 0),
          mode: 0,
          inputs: const [],
          outputs: const [],
          widgetsValues: const [512], // only 'width', 'note' has no slot
          properties: const {},
        );

        final result = ComfyUiGraphConverter.convert(
          graph: UiFormatGraph(nodes: [node], links: const []),
          objectInfo: schema,
        );

        expect(result, isA<ConvertedPrompt>());
        final inputs = ((result as ConvertedPrompt).prompt['1'] as Map)['inputs']
            as Map;
        expect(inputs['width'], 512);
        expect(inputs.containsKey('note'), isFalse);
      },
    );
  });
}
