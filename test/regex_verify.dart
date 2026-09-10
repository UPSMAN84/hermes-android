void main() {
  final p = RegExp(
    r'(?:[\\/:]|\n|\t)([A-Za-z0-9_\-]+\.(?:png|jpe?g|webp|mp4|webm|mkv|mov|gif))',
    caseSensitive: false,
  );
  final cases = <String, String>{
    'normal win path': r'C:\output\TG_00084_.png',
    'double backslash': r'C:\\output\\TG_00084_.png',
    'real newline': 'rendered: C:\\output\nKrea_Upscale_00033_.png',
    'tab before': 'rendered: C:\\output\tKrea_Upscale_00033_.png',
    'space before - should NOT match': 'rendered: TG_00084_.png',
    'literal backslash-n after escapeRe': 'rendered: C:\\output\nKrea_Upscale_00033_.png',
  };
  cases.forEach((name, s) {
    final m = p.allMatches(s).map((e) => e.group(1)).toList();
    print('$name: $m');
  });
}