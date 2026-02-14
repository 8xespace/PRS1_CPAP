// lib/features/web_zip/zip_picker.dart
//
// Conditional import wrapper for picking a .zip file on Web.

export 'zip_picker_stub.dart' if (dart.library.html) 'zip_picker_web.dart';
