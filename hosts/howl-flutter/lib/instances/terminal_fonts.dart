import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'font_assets.dart';

Future<FontAssetMaterializer>? _packaged;

Future<FontAssetMaterializer> _openPackagedFonts() async {
  final directory = await getApplicationSupportDirectory();
  return FontAssetMaterializer(Directory('${directory.path}/terminal-fonts'), (
    asset,
  ) async {
    final bytes = await rootBundle.load(asset);
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  });
}

/// Native Text requires real font files; the host owns platform selection.
Future<(String, List<String>)> terminalFonts() async {
  if (Platform.isAndroid || Platform.isIOS) {
    // Cache the pending directory discovery too, so simultaneous observers
    // cannot create competing materializers before its first await finishes.
    final pending = _packaged ??= _openPackagedFonts();
    try {
      final materializer = await pending;
      final paths = await materializer.ensure(packagedTerminalFonts);
      return (paths.first, paths.skip(1).toList(growable: false));
    } catch (_) {
      if (identical(_packaged, pending)) _packaged = null;
      rethrow;
    }
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
