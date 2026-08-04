String resolveTtsBaseUrl({
  required String configured,
  required String? fallbackHost,
  required int defaultPort,
}) {
  var value = configured.trim();
  final parsed = Uri.tryParse(value.contains('://') ? value : 'http://$value');
  final wildcard = value.isEmpty || parsed == null ||
      parsed.host == '0.0.0.0' || parsed.host == '127.0.0.1' ||
      parsed.host == 'localhost';
  if (wildcard && fallbackHost != null && fallbackHost.trim().isNotEmpty) {
    value = Uri(scheme: 'http', host: fallbackHost.trim(), port: defaultPort).toString();
  }
  if (value.isEmpty) value = 'http://0.0.0.0:$defaultPort';
  if (!value.startsWith('http://') && !value.startsWith('https://')) {
    value = 'http://$value';
  }
  return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
}
