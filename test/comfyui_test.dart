import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/comfyui.dart';

void main() {
  group('ComfyUi.viewUrl', () {
    test('defaults to type=output when unspecified', () {
      expect(
        ComfyUi.viewUrl('http://host:8188', 'pic.png'),
        'http://host:8188/view?filename=pic.png&type=output',
      );
    });

    test('accepts an explicit type', () {
      expect(
        ComfyUi.viewUrl('http://host:8188', 'pic.png', type: 'input'),
        'http://host:8188/view?filename=pic.png&type=input',
      );
    });
  });
}
