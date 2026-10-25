import 'dart:ffi';
import 'dart:io';

import 'package:howl_server_client_render/howl_server_client_render.dart';
import 'package:howl_server_client_render/src/native.dart' show RenderFailure;

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/native_canary.dart LIBRARY FONT_PATH');
    exitCode = 64;
    return;
  }
  final renderer = NativeRenderer.create(
    args[1],
    fallbacks: [args[1]],
    libraryPath: args[0],
  );
  try {
    if (renderer.cellWidth <= 0 || renderer.cellHeight <= 0) {
      throw StateError('Canonical font metrics must be positive');
    }
    try {
      renderer.capture(nullptr);
      throw StateError('Null native snapshot was accepted');
    } on RenderFailure catch (error) {
      if (error.status != 1) rethrow;
    }
    stdout.writeln('HOWL_RENDER_DART_ABI_OK');
  } finally {
    renderer.close();
  }
}
