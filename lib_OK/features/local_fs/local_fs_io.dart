// lib/features/local_fs/local_fs_io.dart

import 'package:path/path.dart' as p;
import 'dart:io';
import 'dart:typed_data';

import '../../core/utils/path_utils.dart';

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
  static Future<List<LocalFsEntry>> listFilesRecursive(String rootPath) async {
    final root = Directory(rootPath);
    final out = <LocalFsEntry>[];

    await for (final ent in root.list(recursive: true, followLinks: false)) {
      if (ent is! File) continue;
      final abs = ent.path;
      final rel = p.relative(abs, from: rootPath);
      final size = await ent.length();
      out.add(LocalFsEntry(absolutePath: abs, relativePath: rel, size: size));
    }

    return out;
  }

  static Future<Uint8List> readBytes(String absolutePath) async {
    final bytes = await File(absolutePath).readAsBytes();
    return Uint8List.fromList(bytes);
  }
}
