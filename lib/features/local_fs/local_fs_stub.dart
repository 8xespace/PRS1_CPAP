// lib/features/local_fs/local_fs_stub.dart

import 'dart:typed_data';

class LocalFsEntry {
  LocalFsEntry({
    required this.absolutePath,
    required this.relativePath,
    required this.size,
  });

  final String absolutePath;
  final String relativePath;
  final int size;
}

class LocalFs {
  static Future<List<LocalFsEntry>> listFilesRecursive(String rootPath) {
    throw UnsupportedError('Local file system is not available on this platform.');
  }

  static Future<Uint8List> readHead(String absolutePath, int maxBytes) {
    throw UnsupportedError('Local file system is not available on this platform.');
  }

  static Future<Uint8List> readBytes(String absolutePath) {
    throw UnsupportedError('Local file system is not available on this platform.');
  }
}
