import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/comfy_ui_graph.dart';

Map<String, dynamic> _uiGraph({
  List<dynamic>? nodes,
  List<dynamic>? links,
}) => {
  'last_node_id': 2,
  'last_link_id': 1,
  'nodes':
      nodes ??
      [
        {
          'id': 1,
          'type': 'CheckpointLoaderSimple',
          'pos': [0, 0],
          'size': [300, 100],
          'mode': 0,
          'inputs': <dynamic>[],
          'outputs': [
            {'name': 'MODEL', 'type': 'MODEL', 'links': [1]},
          ],
          'properties': {'Node name for S&R': 'CheckpointLoaderSimple'},
          'widgets_values': ['sd_xl_base_1.0.safetensors'],
        },
        {
          'id': 2,
          'type': 'KSampler',
          'pos': [400, 0],
          'size': [315, 262],
          'mode': 0,
          'inputs': [
            {'name': 'model', 'type': 'MODEL', 'link': 1},
          ],
          'outputs': <dynamic>[],
          'properties': {'Node name for S&R': 'KSampler'},
          'widgets_values': [
            156680208700286,
            'randomize',
            20,
            8.0,
            'euler',
            'normal',
            1.0,
          ],
        },
      ],
  'links': links ?? [
    [1, 1, 0, 2, 0, 'MODEL'],
  ],
  'groups': <dynamic>[],
  'config': <String, dynamic>{},
  'extra': <String, dynamic>{},
  'version': 0.4,
};

void main() {
  test('detects UI-format graphs by nodes+links, flat graphs otherwise', () {
    expect(detectGraphShape(_uiGraph()), ComfyGraphShape.uiFormat);
    expect(
      detectGraphShape({
        '1': {
          'class_type': 'KSampler',
          'inputs': <String, dynamic>{},
        },
      }),
      ComfyGraphShape.flatApi,
    );
  });

  test('parses node positions, sockets, and widget values', () {
    final graph = UiFormatGraph.parse(_uiGraph());

    expect(graph.nodes, hasLength(2));
    final loader = graph.nodeById(1)!;
    expect(loader.type, 'CheckpointLoaderSimple');
    expect(loader.pos, (0.0, 0.0));
    expect(loader.outputs.single.type, 'MODEL');
    expect(loader.widgetsValues, ['sd_xl_base_1.0.safetensors']);

    final sampler = graph.nodeById(2)!;
    expect(sampler.inputs.single.link, 1);
    expect(sampler.widgetsValues, hasLength(7));
  });

  test('parses links as positional tuples', () {
    final graph = UiFormatGraph.parse(_uiGraph());

    expect(graph.links, hasLength(1));
    final link = graph.links.single;
    expect(link.originNodeId, 1);
    expect(link.originSlot, 0);
    expect(link.targetNodeId, 2);
    expect(link.targetSlot, 0);
    expect(link.type, 'MODEL');
  });

  test('parses links serialized as objects', () {
    final graph = UiFormatGraph.parse(
      _uiGraph(
        links: [
          {
            'id': 1,
            'origin_id': 1,
            'origin_slot': 0,
            'target_id': 2,
            'target_slot': 0,
            'type': 'MODEL',
          },
        ],
      ),
    );

    expect(graph.links.single.originNodeId, 1);
  });

  test('skips malformed nodes/links rather than throwing', () {
    final graph = UiFormatGraph.parse(
      _uiGraph(
        links: [
          [1, 1, 0, 2, 0, 'MODEL'],
          ['not-an-id', 1, 0, 2, 0, 'MODEL'],
        ],
      ),
    );

    expect(graph.links, hasLength(1));
  });

  test('accepts widgets_values serialized as a dict', () {
    final graph = UiFormatGraph.parse(
      _uiGraph(
        nodes: [
          {
            'id': 1,
            'type': 'SomeDynamicNode',
            'pos': [0, 0],
            'size': [200, 100],
            'mode': 0,
            'inputs': <dynamic>[],
            'outputs': <dynamic>[],
            'properties': <String, dynamic>{},
            'widgets_values': {'0': 'a', '1': 'b'},
          },
        ],
        links: <dynamic>[],
      ),
    );

    expect(graph.nodeById(1)!.widgetsValues, ['a', 'b']);
  });

  test('rejects a graph with no nodes', () {
    expect(
      () => UiFormatGraph.parse(_uiGraph(nodes: <dynamic>[])),
      throwsFormatException,
    );
  });

}
