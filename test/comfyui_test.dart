import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/comfy_workflow.dart';
import 'package:hermes_android/core/services/comfyui.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  test('preserves proxy path and encodes output query', () {
    final endpoint = ComfyEndpoint.parse('https://host.example/comfy');
    final uri = endpoint.viewUri(
      ComfyOutputRef(
        filename: 'clip 01.mp4',
        subfolder: 'jobs/a',
        type: 'output',
      ),
    );

    expect(uri.path, '/comfy/view');
    expect(uri.queryParameters, {
      'filename': 'clip 01.mp4',
      'subfolder': 'jobs/a',
      'type': 'output',
    });
  });

  test('rejects unsafe base components', () {
    for (final raw in [
      'https://user@host/comfy',
      'https://host/comfy?token=x',
      'https://host/comfy#fragment',
    ]) {
      expect(() => ComfyEndpoint.parse(raw), throwsFormatException);
    }
  });

  test('uses matching websocket scheme and proxy path', () {
    final endpoint = ComfyEndpoint.parse('https://host.example/comfy');

    expect(
      endpoint.websocketUri('client id').toString(),
      'wss://host.example/comfy/ws?clientId=client+id',
    );
  });

  test('rejects unsafe output references', () {
    expect(
      () => ComfyOutputRef(filename: '../clip.mp4'),
      throwsFormatException,
    );
    expect(
      () => ComfyOutputRef(filename: 'clip.mp4', subfolder: 'jobs/../a'),
      throwsFormatException,
    );
    expect(
      () => ComfyOutputRef(filename: 'clip.mp4', type: 'custom'),
      throwsFormatException,
    );
  });

  test('rejects rooted and drive-qualified output subfolders', () {
    for (final subfolder in ['/etc', '\\Windows', 'C:\\Windows']) {
      expect(
        () => ComfyOutputRef(filename: 'clip.mp4', subfolder: subfolder),
        throwsFormatException,
      );
    }
  });

  test('migrates only missing and wildcard placeholder values', () async {
    SharedPreferences.setMockInitialValues({});
    expect(
      await ComfyUiPrefs.loadConfiguredEndpoint(
        await SharedPreferences.getInstance(),
      ),
      isNull,
    );

    for (final raw in ['http://0.0.0.0:8188', 'http://0.0.0.0:8188/']) {
      SharedPreferences.setMockInitialValues({ComfyUiPrefs.baseUrl: raw});
      expect(
        await ComfyUiPrefs.loadConfiguredEndpoint(
          await SharedPreferences.getInstance(),
        ),
        isNull,
      );
    }

    for (final raw in [
      'https://host/comfy',
      'http://127.0.0.1:8188',
      'http://localhost:8188',
      'http://0.0.0.0:8189',
      'http://0.0.0.0:8188/comfy',
    ]) {
      SharedPreferences.setMockInitialValues({ComfyUiPrefs.baseUrl: raw});
      expect(
        (await ComfyUiPrefs.loadConfiguredEndpoint(
          await SharedPreferences.getInstance(),
        ))!.baseUri.toString(),
        raw,
      );
    }
  });
}
