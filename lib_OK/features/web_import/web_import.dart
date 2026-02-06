// lib/features/web_import/web_import.dart
//
// Unified web import API with conditional implementation.
// - On Web: uses <input webkitdirectory> to pick a folder and enumerate files with relative paths.
// - On other platforms: stub returns null.
//
export 'web_import_stub.dart'
    if (dart.library.html) 'web_import_html.dart';
