import 'dart:io';

/// Native Text requires real font files; the host owns platform selection.
Future<(String, List<String>)> terminalFonts() async {
  if (Platform.isAndroid) {
    // Confirmed on the Note10 Android canary. Other devices fail explicitly
    // until this host ships its own independently licensed font asset.
    const primary = '/system/fonts/DroidSansMono.ttf';
    if (!await File(primary).exists()) {
      throw StateError('Android monospace font unavailable: $primary');
    }
    const candidates = [
      '/system/fonts/NotoNaskhArabic-Regular.ttf',
      '/system/fonts/NotoSansCJK-Regular.ttc',
    ];
    final fallback = <String>[];
    for (final path in candidates) {
      if (await File(path).exists()) fallback.add(path);
    }
    return (primary, fallback);
  }
  if (Platform.isLinux) {
    final configured = Platform.environment['HOWL_FONT_PATH'];
    if (configured != null && configured.isNotEmpty) {
      if (!await File(configured).exists()) {
        throw StateError('Configured terminal font unavailable');
      }
      return (configured, const <String>[]);
    }
    final selected = await Process.run('fc-match', [
      '-f',
      '%{file}\n',
      'IosevkaTerm Nerd Font',
    ]);
    if (selected.exitCode != 0) {
      throw StateError('Fontconfig failed to resolve a terminal font');
    }
    final path = (selected.stdout as String).trim();
    if (path.isEmpty || !await File(path).exists()) {
      throw StateError('Fontconfig returned no usable font');
    }
    return (path, const <String>[]);
  }
  throw UnsupportedError('Native terminal font provisioning is not available');
}
