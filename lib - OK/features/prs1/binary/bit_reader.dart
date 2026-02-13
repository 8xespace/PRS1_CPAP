// lib/features/prs1/binary/bit_reader.dart

import 'dart:typed_data';

/// Bit-level reader for little-endian packed streams.
///
/// Many PRS1 records store fields with non-byte alignment.
class BitReader {
  BitReader(this._data, {int byteOffset = 0})
      : _byteOffset = byteOffset,
        _bitBuffer = 0,
        _bitCount = 0;

  final Uint8List _data;
  int _byteOffset;
  int _bitBuffer;
  int _bitCount;

  int get byteOffset => _byteOffset;

  bool get isEof => _byteOffset >= _data.length && _bitCount == 0;

  /// Align to next byte boundary.
  void alignByte() {
    _bitBuffer = 0;
    _bitCount = 0;
  }

  /// Read [n] bits (1..32), little-endian within the bit stream.
  int readBits(int n) {
    if (n <= 0 || n > 32) throw ArgumentError('n must be 1..32');
    while (_bitCount < n) {
      if (_byteOffset >= _data.length) {
        throw RangeError('BitReader EOF while reading $n bits');
      }
      _bitBuffer |= (_data[_byteOffset++] << _bitCount);
      _bitCount += 8;
    }
    final mask = n == 32 ? 0xFFFFFFFF : ((1 << n) - 1);
    final out = _bitBuffer & mask;
    _bitBuffer >>= n;
    _bitCount -= n;
    return out;
  }

  int readBool() => readBits(1);
}
