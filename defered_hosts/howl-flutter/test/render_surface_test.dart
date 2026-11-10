import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:howl_server_client_render/howl_server_client_render.dart';
import 'package:howl_sessions/instances/render_surface.dart';

RenderFrame frame({
  List<RenderUpload> uploads = const [],
  List<RenderKey> removals = const [],
  bool glyph = false,
}) {
  final commands = Uint8List(glyph ? 64 : 0);
  if (glyph) {
    final data = ByteData.sublistView(commands);
    data.setUint64(0, 1, Endian.host);
    data.setUint64(8, 1, Endian.host);
    data.setUint32(16, 0xffffffff, Endian.host);
    data.setUint16(36, 1, Endian.host);
    data.setUint16(38, 1, Endian.host);
    data.setUint16(40, 1, Endian.host);
    data.setUint16(42, 1, Endian.host);
    data.setUint16(48, 1, Endian.host);
    data.setUint16(50, 1, Endian.host);
    data.setUint16(52, 1, Endian.host);
    data.setUint16(54, 1, Endian.host);
    data.setUint8(56, 1);
  }
  return RenderFrame(
    revision: 1,
    contentRevision: 1,
    terminalRevision: 1,
    width: 1,
    height: 1,
    cellWidth: 1,
    cellHeight: 1,
    backgroundRgba: 0,
    alternateScreen: false,
    commands: commands,
    uploads: uploads,
    removals: removals,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only decoded textures are reported as resident', () async {
    final textures = RenderTextures();
    const alpha = [255];
    final key = RenderKey(BigInt.one, BigInt.one);
    final residency = RenderResidency(key, 1, 1, 0);
    try {
      await textures.apply(
        frame(
          glyph: true,
          uploads: [RenderUpload(residency, 1, Uint8List.fromList(alpha))],
        ),
      );
      expect(textures.resident, hasLength(1));
      expect(textures.resident.single.key, key);
      await expectLater(
        textures.apply(frame(glyph: true, removals: [key])),
        throwsStateError,
      );
      // Failed updates preserve old residency for the next native capture.
      expect(textures.resident, hasLength(1));
      await textures.apply(frame(removals: [key]));
      textures.finishFrame();
      expect(textures.resident, isEmpty);
    } finally {
      textures.close();
    }
  });

  test('invalid upload cannot evict the previous decoded texture', () async {
    final textures = RenderTextures();
    final key = RenderKey(BigInt.one, BigInt.one);
    final valid = RenderResidency(key, 1, 1, 0);
    try {
      await textures.apply(
        frame(
          uploads: [
            RenderUpload(valid, 1, Uint8List.fromList([255])),
          ],
        ),
      );
      final invalid = RenderResidency(
        RenderKey(BigInt.two, BigInt.one),
        0,
        1,
        0,
      );
      await expectLater(
        textures.apply(
          frame(
            uploads: [
              RenderUpload(invalid, 1, Uint8List.fromList([0])),
            ],
          ),
        ),
        throwsFormatException,
      );
      expect(textures.resident.map((r) => r.key), [key]);
    } finally {
      textures.close();
    }
  });

  test('a newer atlas generation replaces the same resource slot', () async {
    final textures = RenderTextures();
    final oldKey = RenderKey(BigInt.one, BigInt.one);
    final newKey = RenderKey(BigInt.one, BigInt.two);
    try {
      await textures.apply(
        frame(
          uploads: [
            RenderUpload(
              RenderResidency(oldKey, 1, 1, 0),
              1,
              Uint8List.fromList([255]),
            ),
          ],
        ),
      );
      await textures.apply(
        frame(
          uploads: [
            RenderUpload(
              RenderResidency(newKey, 1, 1, 0),
              1,
              Uint8List.fromList([127]),
            ),
          ],
        ),
      );
      expect(textures.resident.map((entry) => entry.key), [newKey]);
      expect(() => textures.image(oldKey), throwsStateError);
      expect(textures.image(newKey), isNotNull);
      textures.finishFrame();
    } finally {
      textures.close();
    }
  });

  testWidgets('Flutter paints an uploaded canonical alpha command', (
    tester,
  ) async {
    final textures = RenderTextures();
    final key = RenderKey(BigInt.one, BigInt.one);
    final value = frame(
      glyph: true,
      uploads: [
        RenderUpload(
          RenderResidency(key, 1, 1, 0),
          1,
          Uint8List.fromList([255]),
        ),
      ],
    );
    try {
      await tester.runAsync(() => textures.apply(value));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 100,
              height: 100,
              child: RenderCanvas(frame: value, textures: textures),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      textures.finishFrame();
    } finally {
      textures.close();
    }
  });
}
