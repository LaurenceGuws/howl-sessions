final _modulus = BigInt.one << 64;
final _maximum = _modulus - BigInt.one;
final _signedMaximum = (BigInt.one << 63) - BigInt.one;

/// C IDs are unsigned u64, while Dart VM integers expose signed low bits.
BigInt fromNativeIdentity(int value) => BigInt.from(value).toUnsigned(64);

int toNativeIdentity(BigInt value) {
  if (value <= BigInt.zero || value > _maximum) {
    throw ArgumentError.value(value, 'identity', 'must fit nonzero u64');
  }
  // BigInt.toInt clamps out-of-range values to signed INT64_MAX. Convert the
  // exact low bits into their signed two's-complement representative first;
  // the @Uint64 FFI boundary then preserves those bits unchanged.
  final signed = value > _signedMaximum ? value - _modulus : value;
  return signed.toInt();
}
