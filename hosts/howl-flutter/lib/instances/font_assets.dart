import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

typedef FontAssetLoader = Future<Uint8List> Function(String asset);

/// The exact redistributed files, not a claim of universal Unicode coverage.
const packagedTerminalFonts = <PackagedFont>[
  PackagedFont(
    asset: 'assets/fonts/IosevkaTermNerdFont-Regular.ttf',
    filename: 'IosevkaTermNerdFont-Regular.ttf',
    length: 13230756,
    digest: 'd5116846a175ef4a988f61241dd3572d6a9dd3e09d4d168c67954b10783a7880',
  ),
  PackagedFont(
    asset: 'assets/fonts/NotoSans-Regular.ttf',
    filename: 'NotoSans-Regular.ttf',
    length: 621572,
    digest: '478c558ea716033cd60c03438f628dfa75694dcf6b5f6d505a2f05fd2b4f3823',
  ),
];

final class PackagedFont {
  const PackagedFont({
    required this.asset,
    required this.filename,
    required this.length,
    required this.digest,
  });

  final String asset;
  final String filename;
  final int length;
  final String digest;
}

/// Coalesces concurrent callers. Failures are retryable, never cached forever.
final class FontAssetMaterializer {
  FontAssetMaterializer(this.directory, this.load);

  final Directory directory;
  final FontAssetLoader load;
  Future<List<String>>? _pending;

  Future<List<String>> ensure(List<PackagedFont> fonts) {
    return _pending ??= _run(fonts).whenComplete(() => _pending = null);
  }

  Future<List<String>> _run(List<PackagedFont> fonts) async {
    await directory.create(recursive: true);
    final paths = <String>[];
    for (final font in fonts) {
      if (font.filename.isEmpty ||
          font.filename == '.' ||
          font.filename == '..' ||
          font.filename.contains('/') ||
          font.filename.contains('\\') ||
          font.length <= 0 ||
          font.length > 32 * 1024 * 1024) {
        throw StateError('Invalid packaged font specification');
      }

      final file = File('${directory.path}/${font.filename}');
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.link ||
          (type != FileSystemEntityType.notFound &&
              type != FileSystemEntityType.file)) {
        throw StateError('Packaged font destination is not a regular file');
      }
      if (type == FileSystemEntityType.file && await _valid(file, font)) {
        paths.add(file.path);
        continue;
      }

      final bytes = await load(font.asset);
      if (bytes.length != font.length ||
          sha256.convert(bytes).toString() != font.digest) {
        throw StateError(
          'Bundled font asset failed integrity check: ${font.asset}',
        );
      }

      // A private same-filesystem stage permits atomic publication. Each
      // contender owns its stage; readers never see a truncated final file.
      final stage = await directory.createTemp('.font-stage-');
      try {
        final staged = File('${stage.path}/${font.filename}');
        await staged.writeAsBytes(bytes, flush: true);
        if (!await _valid(staged, font)) {
          throw StateError('Staged font asset failed verification');
        }
        await staged.rename(file.path);
      } finally {
        await stage.delete(recursive: true);
      }
      paths.add(file.path);
    }
    return paths;
  }

  static Future<bool> _valid(File file, PackagedFont font) async {
    if (await file.length() != font.length) return false;
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == font.digest;
  }
}
