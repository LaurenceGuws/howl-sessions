import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:howl_server_client_render/howl_server_client_render.dart';

final class RenderTextures {
  // One backend slot per resource ID; atlas generations replace that slot.
  final Map<BigInt, _Texture> _live = {};
  final List<ui.Image> _retired = [];
  bool _closed = false;

  List<RenderResidency> get resident =>
      List.unmodifiable(_live.values.map((entry) => entry.residency));

  /// Decode the entire update before changing what the backend claims to own.
  /// On failure, the prior frame and its textures remain intact.
  Future<void> apply(RenderFrame frame) async {
    if (_closed) throw StateError('Render textures closed');
    final decoded = <BigInt, _Texture>{};
    try {
      for (final upload in frame.uploads) {
        if (decoded.containsKey(upload.residency.key.resource)) {
          throw const FormatException('Duplicate native Render upload');
        }
        decoded[upload.residency.key.resource] = _Texture(
          upload.residency,
          await _decode(upload),
        );
      }
      if (_closed) throw StateError('Render textures closed during decode');
      final next = {..._live};
      for (final key in frame.removals) {
        next.remove(key.resource);
      }
      next.addAll(decoded);
      for (var i = 0; i < frame.commandCount; i++) {
        final command = frame.command(i);
        if (command.tag < 0 || command.tag > 2) {
          throw const FormatException('Unknown native Render command');
        }
        if (command.tag != 0 &&
            next[command.key.resource]?.residency.key != command.key) {
          throw StateError('Missing native Render texture');
        }
      }
      for (final entry in _live.entries) {
        if (!identical(next[entry.key], entry.value)) {
          _retired.add(entry.value.image);
        }
      }
      _live
        ..clear()
        ..addAll(next);
    } catch (_) {
      for (final texture in decoded.values) {
        texture.image.dispose();
      }
      rethrow;
    }
  }

  /// Called after Flutter has finished painting the replacement frame.
  void finishFrame() {
    for (final image in _retired) {
      image.dispose();
    }
    _retired.clear();
  }

  ui.Image image(RenderKey key) {
    final texture = _live[key.resource];
    if (texture == null || texture.residency.key != key) {
      throw StateError('Native Render texture was not resident');
    }
    return texture.image;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final texture in _live.values) {
      texture.image.dispose();
    }
    _live.clear();
    finishFrame();
  }
}

final class _Texture {
  const _Texture(this.residency, this.image);
  final RenderResidency residency;
  final ui.Image image;
}

Future<ui.Image> _decode(RenderUpload upload) async {
  final resource = upload.residency;
  final width = resource.width;
  final height = resource.height;
  final format = resource.format;
  final pixelSize = format == 0 ? 1 : 4;
  if (width == 0 ||
      height == 0 ||
      width > 4096 ||
      height > 4096 ||
      (format != 0 && format != 1) ||
      upload.stride < width * pixelSize ||
      upload.stride * height > upload.pixels.length ||
      width * height * 4 > 80 * 1024 * 1024) {
    throw const FormatException('Invalid native Render texture');
  }
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final source = y * upload.stride + x * pixelSize;
      final dest = (y * width + x) * 4;
      if (format == 0) {
        rgba[dest] = 255;
        rgba[dest + 1] = 255;
        rgba[dest + 2] = 255;
        rgba[dest + 3] = upload.pixels[source];
      } else {
        rgba.setRange(dest, dest + 4, upload.pixels, source);
      }
    }
  }
  final result = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    result.complete,
    rowBytes: width * 4,
  );
  return result.future;
}

/// Flutter presentation of canonical native drawing commands, never cells.
final class RenderCanvas extends StatelessWidget {
  const RenderCanvas({super.key, required this.frame, required this.textures});

  final RenderFrame frame;
  final RenderTextures textures;

  @override
  Widget build(BuildContext context) => InteractiveViewer(
    constrained: false,
    minScale: 0.4,
    maxScale: 3,
    child: SizedBox(
      width: frame.width.toDouble(),
      height: frame.height.toDouble(),
      child: CustomPaint(painter: _RenderPainter(frame, textures)),
    ),
  );
}

final class _RenderPainter extends CustomPainter {
  const _RenderPainter(this.frame, this.textures);
  final RenderFrame frame;
  final RenderTextures textures;

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    for (var i = 0; i < frame.commandCount; i++) {
      final command = frame.command(i);
      final destination = ui.Rect.fromLTWH(
        command.x.toDouble(),
        command.y.toDouble(),
        command.width.toDouble(),
        command.height.toDouble(),
      );
      final clip = ui.Rect.fromLTWH(
        command.clipX.toDouble(),
        command.clipY.toDouble(),
        command.clipWidth.toDouble(),
        command.clipHeight.toDouble(),
      );
      if (destination.intersect(clip).isEmpty) continue;
      canvas.save();
      canvas.clipRect(clip);
      if (command.tag == 0) {
        canvas.drawRect(
          destination,
          ui.Paint()..color = _color(command.colorRgba),
        );
      } else {
        final source = ui.Rect.fromLTWH(
          command.sourceX.toDouble(),
          command.sourceY.toDouble(),
          command.sourceWidth.toDouble(),
          command.sourceHeight.toDouble(),
        );
        final paint = ui.Paint()..filterQuality = ui.FilterQuality.none;
        if (command.tag == 1) {
          paint.colorFilter = ui.ColorFilter.mode(
            _color(command.colorRgba),
            ui.BlendMode.srcIn,
          );
        }
        canvas.drawImageRect(
          textures.image(command.key),
          source,
          destination,
          paint,
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _RenderPainter old) =>
      !identical(frame, old.frame) || !identical(textures, old.textures);
}

ui.Color _color(int rgba) => ui.Color.fromARGB(
  (rgba >> 24) & 255,
  rgba & 255,
  (rgba >> 8) & 255,
  (rgba >> 16) & 255,
);
