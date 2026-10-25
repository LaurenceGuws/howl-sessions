import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:howl_server_client/src/native_identity.dart';

/// Exhausts the signed/unsigned 64-bit seam at its critical boundaries.
void main() {
  final boundary = BigInt.one << 63;
  final maximum = (BigInt.one << 64) - BigInt.one;
  final native = calloc<Uint64>();
  try {
    for (final id in [
      BigInt.one,
      boundary - BigInt.one,
      boundary,
      boundary + BigInt.one,
      maximum,
    ]) {
      native.value = toNativeIdentity(id);
      if (fromNativeIdentity(native.value) != id) {
        throw StateError('Native u64 identity roundtrip failed for $id');
      }
    }
    for (final invalid in [BigInt.zero, -BigInt.one, maximum + BigInt.one]) {
      try {
        toNativeIdentity(invalid);
      } on ArgumentError {
        continue;
      }
      throw StateError('Invalid u64 identity accepted: $invalid');
    }
  } finally {
    calloc.free(native);
  }
  print('native identity canary PASS (signed boundary and u64 maximum)');
}
