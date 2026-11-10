import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:howl_sessions/instances/font_assets.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('howl-font-test-');
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  PackagedFont spec(Uint8List bytes) => PackagedFont(
    asset: 'fixture.ttf',
    filename: 'fixture.ttf',
    length: bytes.length,
    digest: sha256.convert(bytes).toString(),
  );

  test('real bundled fonts match their advertised byte identities', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final font in packagedTerminalFonts) {
      final data = await rootBundle.load(font.asset);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      expect(bytes.length, font.length);
      expect(sha256.convert(bytes).toString(), font.digest);
    }
    final license = await rootBundle.loadString(
      'LICENSES/redistributed-fonts.txt',
    );
    expect(license, contains('SIL Open Font License'));
  });

  test(
    'first extraction is verified; next invocation leaves file intact',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      var loads = 0;
      final materializer = FontAssetMaterializer(temporary, (_) async {
        loads++;
        return bytes;
      });
      final first = await materializer.ensure([spec(bytes)]);
      final modifiedAt = await File(first.single).lastModified();
      final second = await materializer.ensure([spec(bytes)]);
      expect(second, first);
      expect(loads, 1);
      expect(await File(first.single).readAsBytes(), bytes);
      expect(await File(first.single).lastModified(), modifiedAt);
    },
  );

  test(
    'truncated and same-length corrupt installed bytes are repaired',
    () async {
      final bytes = Uint8List.fromList([10, 20, 30]);
      var loads = 0;
      final materializer = FontAssetMaterializer(temporary, (_) async {
        loads++;
        return bytes;
      });
      final path = (await materializer.ensure([spec(bytes)])).single;
      await File(path).writeAsBytes([10]);
      await materializer.ensure([spec(bytes)]);
      expect(await File(path).readAsBytes(), bytes);
      await File(path).writeAsBytes([10, 21, 30]);
      await materializer.ensure([spec(bytes)]);
      expect(await File(path).readAsBytes(), bytes);
      expect(loads, 3);
    },
  );

  test('bad or missing bundle leaves no published partial font', () async {
    final good = Uint8List.fromList([7, 8, 9]);
    final missing = FontAssetMaterializer(
      temporary,
      (_) => Future<Uint8List>.error(StateError('asset not found')),
    );
    await expectLater(missing.ensure([spec(good)]), throwsStateError);
    expect(await temporary.list().toList(), isEmpty);

    final corrupt = FontAssetMaterializer(
      temporary,
      (_) async => Uint8List.fromList([7, 8, 0]),
    );
    await expectLater(corrupt.ensure([spec(good)]), throwsStateError);
    expect(await temporary.list().toList(), isEmpty);
  });

  test(
    'parallel callers share one materialization and can retry failures',
    () async {
      final bytes = Uint8List.fromList([4, 5, 6]);
      var loads = 0;
      var fail = true;
      final materializer = FontAssetMaterializer(temporary, (_) async {
        loads++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (fail) throw StateError('temporary failure');
        return bytes;
      });
      final first = materializer.ensure([spec(bytes)]);
      final second = materializer.ensure([spec(bytes)]);
      await expectLater(first, throwsStateError);
      await expectLater(second, throwsStateError);
      expect(loads, 1);

      fail = false;
      final restored = await Future.wait([
        materializer.ensure([spec(bytes)]),
        materializer.ensure([spec(bytes)]),
      ]);
      expect(restored[0], restored[1]);
      expect(loads, 2);
    },
  );

  test('symlink destination and unsafe filename are refused', () async {
    final bytes = Uint8List.fromList([1, 2]);
    final outside = File('${temporary.path}/outside')..writeAsBytesSync(bytes);
    await Link('${temporary.path}/fixture.ttf').create(outside.path);
    final materializer = FontAssetMaterializer(temporary, (_) async => bytes);
    await expectLater(materializer.ensure([spec(bytes)]), throwsStateError);
    expect(await outside.readAsBytes(), bytes);

    final unsafe = PackagedFont(
      asset: 'fixture.ttf',
      filename: '../escape.ttf',
      length: bytes.length,
      digest: sha256.convert(bytes).toString(),
    );
    await expectLater(materializer.ensure([unsafe]), throwsStateError);
  });
}
