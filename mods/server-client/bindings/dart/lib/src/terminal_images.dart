import 'dart:typed_data';

/// Exact Server image occurrence. These are not Render resource IDs or residency.
final class TerminalImageIdentity {
  const TerminalImageIdentity({
    required this.id,
    required this.generation,
    required this.width,
    required this.height,
  });
  static const maximumBytes = 16777216; // HSC_MAX_IMAGE_BYTES, ABI v1.
  static const maximumManifestImages = 256; // SRVR graphics v2.
  final int id, width, height;
  final BigInt generation;

  int get byteLength {
    if (id <= 0 ||
        id > 0xffffffff ||
        generation <= BigInt.zero ||
        generation >= (BigInt.one << 64) ||
        width <= 0 ||
        height <= 0 ||
        width > maximumBytes ~/ 4 ||
        height > maximumBytes ~/ 4 ~/ width) {
      throw const FormatException(
        'Invalid or oversized terminal image identity',
      );
    }
    return width * height * 4;
  }

  @override
  bool operator ==(Object other) =>
      other is TerminalImageIdentity &&
      id == other.id &&
      generation == other.generation &&
      width == other.width &&
      height == other.height;
  @override
  int get hashCode => Object.hash(id, generation, width, height);
}

/// Caller-owned copied RGBA8, independent of native image/snapshot lifetimes.
final class TerminalImageData {
  const TerminalImageData(this.identity, this.pixels);
  final TerminalImageIdentity identity;
  final Uint8List pixels;
}
