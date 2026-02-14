// lib/features/web_zip/zip_picker_stub.dart

import 'dart:typed_data';

import 'web_zip_import.dart';

class ZipPicker {
  static Future<PickedZip?> pickZip() async {
    throw UnsupportedError('ZIP picker is only available on Web');
  }
}
