// lib/features/local_fs/local_fs.dart
//
// Minimal local filesystem adapter with conditional import.
// - On mobile/desktop (dart:io available): real recursive listing + read bytes.
// - On Web: throws UnsupportedError (caller should guard with kIsWeb).

export 'local_fs_stub.dart' if (dart.library.io) 'local_fs_io.dart';
