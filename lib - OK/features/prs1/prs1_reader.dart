// lib/features/prs1/prs1_reader.dart

import 'dart:io';
import 'dart:typed_data';

import '../../core/logging.dart';

/// PRS1 reader: enumerates files and loads bytes from an authorized folder.
///
/// NOTE: This uses dart:io and therefore is not available on Web.
class Prs1Reader {
  const Prs1Reader();

  /// List candidate PRS1 data files in [folderPath].
  ///
  /// DreamStation/PRS1 SD cards typically include subfolders; we do a recursive search.
  Future<List<File>> listFiles(String folderPath) async {
    final root = Directory(folderPath);
    if (!await root.exists()) return const [];

    final out = <File>[];
    await for (final ent in root.list(recursive: true, followLinks: false)) {
      if (ent is! File) continue;
      final name = ent.path.toLowerCase();
      // Common PRS1 files: numeric 3-digit extensions (.000..999) + a few sidecar formats.
      if (RegExp(r'\.\d{3}\$').hasMatch(name) || name.endsWith('.edf') || name.endsWith('.tgt') || name.endsWith('.dat')) {
        out.add(ent);
      }
    }

    Log.i('PRS1 listFiles found ${out.length} files', tag: 'PRS1');
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  Future<Uint8List> readAllBytes(File file) async {
    return file.readAsBytes();
  }
}
