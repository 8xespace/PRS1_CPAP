// lib/core/utils/bytes.dart

import 'dart:typed_data';

String hexOf(Uint8List bytes, {int? maxLen}) {
  final len = maxLen == null ? bytes.length : (bytes.length < maxLen ? bytes.length : maxLen);
  final sb = StringBuffer();
  for (int i = 0; i < len; i++) {
    final v = bytes[i];
    sb.write(v.toRadixString(16).padLeft(2, '0'));
  }
  if (len < bytes.length) sb.write('...');
  return sb.toString();
}

Uint8List sliceBytes(Uint8List src, int offset, int length) {
  if (offset < 0 || length < 0 || offset + length > src.length) {
    throw RangeError('sliceBytes out of range: offset=$offset length=$length srcLen=${src.length}');
  }
  return Uint8List.sublistView(src, offset, offset + length);
}
