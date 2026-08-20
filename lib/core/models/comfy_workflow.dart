final class ComfyEndpoint {
  ComfyEndpoint._(this.baseUri);

  final Uri baseUri;

  factory ComfyEndpoint.parse(String raw) {
    final trimmed = raw.trim();
    final text = trimmed.contains('://') ? trimmed : 'http://$trimmed';
    final uri = Uri.parse(text);
    if (!const {'http', 'https'}.contains(uri.scheme) ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException(
        'ComfyUI endpoint must be HTTP(S) authority plus optional path',
      );
    }
    return ComfyEndpoint._(uri.replace(path: _cleanBasePath(uri.path)));
  }

  static String _cleanBasePath(String path) {
    final withoutTrailingSlash = path.replaceFirst(RegExp(r'/+$'), '');
    if (withoutTrailingSlash.isEmpty) return '';
    return withoutTrailingSlash.startsWith('/')
        ? withoutTrailingSlash
        : '/$withoutTrailingSlash';
  }

  Uri route(String leaf, {Map<String, String>? query}) => baseUri.replace(
    path:
        '${baseUri.path == '/' ? '' : baseUri.path}/${leaf.replaceFirst(RegExp(r'^/+'), '')}',
    queryParameters: query,
  );

  Uri websocketUri(String clientId) => route(
    'ws',
    query: {'clientId': clientId},
  ).replace(scheme: baseUri.scheme == 'https' ? 'wss' : 'ws');

  Uri viewUri(ComfyOutputRef output) => route('view', query: output.query);
}

final class ComfyOutputRef {
  ComfyOutputRef._({
    required this.filename,
    required this.subfolder,
    required this.type,
  });

  factory ComfyOutputRef({
    required String filename,
    String subfolder = '',
    String type = 'output',
  }) {
    if (filename.isEmpty ||
        filename.contains('/') ||
        filename.contains('\\') ||
        filename == '..' ||
        subfolder.startsWith('/') ||
        subfolder.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(subfolder) ||
        subfolder.split(RegExp(r'[/\\]+')).any((part) => part == '..') ||
        !const {'input', 'output', 'temp'}.contains(type)) {
      throw const FormatException('Unsafe ComfyUI output reference');
    }
    return ComfyOutputRef._(
      filename: filename,
      subfolder: subfolder,
      type: type,
    );
  }

  final String filename;
  final String subfolder;
  final String type;

  Map<String, String> get query => {
    'filename': filename,
    if (subfolder.isNotEmpty) 'subfolder': subfolder,
    'type': type,
  };
}
