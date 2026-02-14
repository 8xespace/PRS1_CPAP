// lib/features/prs1/binary/le_reader.dart

import 'dart:convert';
import 'dart:typed_data';

/// Little-endian byte reader.
///
/// This is a small utility used across the PRS1 decoding pipeline.
/// It intentionally offers both method and getter aliases to keep the
/// codebase terse and readable.
class LeReader {
  LeReader(this._data, {int offset = 0}) : _o = offset;

  final Uint8List _data;
  int _o;

  // --- Aliases used by decoders ---
  int get pos => _o;
  bool get eof => _o >= _data.length;
  int get remaining => _data.length - _o;

  int get length => _data.length;

  void seek(int offset) {
    if (offset < 0 || offset > _data.length) {
      throw RangeError('seek out of range: $offset');
    }
    _o = offset;
  }

  void skip(int n) => seek(_o + n);

  Uint8List bytes(int n) => readBytes(n);

  Uint8List readBytes(int n) {
    if (_o + n > _data.length) {
      throw RangeError('readBytes out of range: need=$n remaining=$remaining');
    }
    final v = Uint8List.sublistView(_data, _o, _o + n);
    _o += n;
    return v;
  }

  int u8() {
    if (_o + 1 > _data.length) throw RangeError('u8 out of range');
    return _data[_o++];
  }

  int s8() {
    final v = u8();
    return v >= 0x80 ? v - 0x100 : v;
  }

  int u16() {
    final b0 = u8();
    final b1 = u8();
    return b0 | (b1 << 8);
  }

  int s16() {
    final v = u16();
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  int u32() {
    final b0 = u8();
    final b1 = u8();
    final b2 = u8();
    final b3 = u8();
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
  }

  int s32() {
    final v = u32();
    return (v & 0x80000000) != 0 ? v - 0x100000000 : v;
  }

  int u64() {
    final lo = u32();
    final hi = u32();
    return lo | (hi << 32);
  }

  /// Peek u8 at a relative offset without advancing.
  int peekU8([int rel = 0]) {
    final p = _o + rel;
    if (p < 0 || p >= _data.length) return 0;
    return _data[p];
  }

  /// Peek u16 little-endian at a relative offset without advancing.
  int peekU16([int rel = 0]) {
    final p = _o + rel;
    if (p < 0 || p + 1 >= _data.length) return 0;
    return (_data[p] | (_data[p + 1] << 8)) & 0xFFFF;
  }

  /// Read a fixed-length ASCII/Latin1 string (zero bytes are kept unless [trimNull] is true).
  String str(int n, {bool trimNull = true}) {
    final b = readBytes(n);
    if (!trimNull) return latin1.decode(b);
    int end = b.length;
    for (int i = 0; i < b.length; i++) {
      if (b[i] == 0) {
        end = i;
        break;
      }
    }
    return latin1.decode(b.sublist(0, end));
  }

  /// Read a null-terminated string with an upper bound.
  String cstr({int maxLen = 256}) {
    final start = _o;
    int end = start;
    while (end < _data.length && (end - start) < maxLen) {
      if (_data[end] == 0) break;
      end++;
    }
    final s = latin1.decode(_data.sublist(start, end));
    _o = end < _data.length && _data[end] == 0 ? end + 1 : end;
    return s;
  }
}
