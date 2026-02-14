// lib/features/web_zip/zip_picker_web.dart
//
// Browser file picker for .zip

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'web_zip_import.dart';

class ZipPicker {
  static Future<PickedZip?> pickZip() async {
    final input = html.FileUploadInputElement();
    input.accept = '.zip,application/zip,application/x-zip-compressed';
    input.multiple = false;
    input.click();

    // Wait for selection or cancel.
    await input.onChange.first;
    final files = input.files;
    if (files == null || files.isEmpty) return null;

    final file = files.first;
    final reader = html.FileReader();

    final completer = Completer<PickedZip?>();
    reader.onError.first.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(reader.error ?? 'FileReader error');
      }
    });
    reader.onLoadEnd.first.then((_) {
      final result = reader.result;
      if (result == null) {
        if (!completer.isCompleted) completer.complete(null);
        return;
      }
      // reader.result is ByteBuffer
      final buf = result as ByteBuffer;
      final bytes = Uint8List.view(buf);
      if (!completer.isCompleted) {
        completer.complete(PickedZip(name: file.name, bytes: bytes));
      }
    });

    reader.readAsArrayBuffer(file);
    return completer.future;
  }
}
