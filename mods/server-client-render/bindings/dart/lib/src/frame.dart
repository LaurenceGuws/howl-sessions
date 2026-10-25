import 'dart:typed_data';

/// Render's exact resource occurrence, not a Flutter texture handle.
final class RenderKey {
  const RenderKey(this.resource, this.generation);
  final BigInt resource;
  final BigInt generation;

  @override
  bool operator ==(Object other) =>
      other is RenderKey &&
      other.resource == resource &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(resource, generation);
}

/// Resource truth supplied by the drawing backend on the next capture.
final class RenderResidency {
  const RenderResidency(this.key, this.width, this.height, this.format);
  final RenderKey key;
  final int width;
  final int height;
  final int format;
}

/// Copied pixels; their lifetime is independent of the native frame lease.
final class RenderUpload {
  const RenderUpload(this.residency, this.stride, this.pixels);
  final RenderResidency residency;
  final int stride;
  final Uint8List pixels;
}

/// One immutable copy of a canonical hrc_command (64-byte ABI v1).
final class RenderCommand {
  const RenderCommand({
    required this.key,
    required this.colorRgba,
    required this.x,
    required this.y,
    required this.clipX,
    required this.clipY,
    required this.width,
    required this.height,
    required this.clipWidth,
    required this.clipHeight,
    required this.sourceX,
    required this.sourceY,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.resourceWidth,
    required this.resourceHeight,
    required this.tag,
    required this.format,
    required this.cursorComponent,
  });

  final RenderKey key;
  final int colorRgba;
  final int x, y, clipX, clipY;
  final int width, height, clipWidth, clipHeight;
  final int sourceX, sourceY, sourceWidth, sourceHeight;
  final int resourceWidth, resourceHeight;
  final int tag, format, cursorComponent;
}

/// One copied Howl Render frame, with no cell grid or font semantics.
///
/// Commands remain in native ABI v1 order and are decoded on demand so that
/// a large terminal redraw does not allocate one Dart object per command.
final class RenderFrame {
  RenderFrame({
    required this.revision,
    required this.contentRevision,
    required this.terminalRevision,
    required this.width,
    required this.height,
    required this.cellWidth,
    required this.cellHeight,
    required this.backgroundRgba,
    required this.alternateScreen,
    required this.uploads,
    required this.removals,
    required Uint8List commands,
  }) : _commands = commands,
       _data = ByteData.sublistView(commands) {
    if (commands.lengthInBytes % 64 != 0) {
      throw const FormatException('Howl Render command ABI length');
    }
  }

  final int revision, contentRevision, terminalRevision;
  final int width, height, cellWidth, cellHeight;
  final int backgroundRgba;
  final bool alternateScreen;
  final List<RenderUpload> uploads;
  final List<RenderKey> removals;
  final Uint8List _commands;
  final ByteData _data;

  int get commandCount => _commands.lengthInBytes ~/ 64;

  RenderCommand command(int index) {
    if (index < 0 || index >= commandCount) {
      throw RangeError.index(index, _commands, 'command');
    }
    final at = index * 64;
    final data = _data;
    return RenderCommand(
      key: RenderKey(
        BigInt.from(data.getUint64(at, Endian.host)).toUnsigned(64),
        BigInt.from(data.getUint64(at + 8, Endian.host)).toUnsigned(64),
      ),
      colorRgba: data.getUint32(at + 16, Endian.host),
      x: data.getInt32(at + 20, Endian.host),
      y: data.getInt32(at + 24, Endian.host),
      clipX: data.getInt32(at + 28, Endian.host),
      clipY: data.getInt32(at + 32, Endian.host),
      width: data.getUint16(at + 36, Endian.host),
      height: data.getUint16(at + 38, Endian.host),
      clipWidth: data.getUint16(at + 40, Endian.host),
      clipHeight: data.getUint16(at + 42, Endian.host),
      sourceX: data.getUint16(at + 44, Endian.host),
      sourceY: data.getUint16(at + 46, Endian.host),
      sourceWidth: data.getUint16(at + 48, Endian.host),
      sourceHeight: data.getUint16(at + 50, Endian.host),
      resourceWidth: data.getUint16(at + 52, Endian.host),
      resourceHeight: data.getUint16(at + 54, Endian.host),
      tag: data.getUint8(at + 56),
      format: data.getUint8(at + 57),
      cursorComponent: data.getUint8(at + 58),
    );
  }
}
