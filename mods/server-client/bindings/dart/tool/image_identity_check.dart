import 'dart:convert';

import 'package:howl_server_client/howl_server_client.dart';

void main() {
  TerminalImageIdentity identity({
    int id = 1,
    BigInt? generation,
    int width = 1,
    int height = 1,
  }) => TerminalImageIdentity(
    id: id,
    generation: generation ?? BigInt.one,
    width: width,
    height: height,
  );
  var rejected = 0;
  for (final image in [
    identity(id: 0),
    identity(id: -1),
    identity(id: 0x100000000),
    identity(generation: BigInt.zero),
    identity(generation: BigInt.one << 64),
    identity(width: 0),
    identity(height: 0),
    identity(width: -1),
    identity(height: -1),
    identity(width: 0xffffffff, height: 0xffffffff),
    identity(width: 2048, height: 2049),
  ]) {
    try {
      image.byteLength;
    } on FormatException {
      rejected++;
      continue;
    }
    throw StateError('Invalid image identity accepted');
  }
  if (identity(width: 2048, height: 2048).byteLength !=
          TerminalImageIdentity.maximumBytes ||
      identity(
            id: 0xffffffff,
            generation: (BigInt.one << 64) - BigInt.one,
          ).byteLength !=
          4 ||
      identity() != identity() ||
      identity().hashCode != identity().hashCode) {
    throw StateError('Boundary or exact identity check failed');
  }
  print(
    jsonEncode({
      'status': 'pass',
      'rejected': rejected,
      'max_rgba_bytes': TerminalImageIdentity.maximumBytes,
      'unsigned_generation': true,
      'overflow_preflight': true,
    }),
  );
}
