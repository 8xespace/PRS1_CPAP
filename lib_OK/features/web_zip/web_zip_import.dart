// lib/features/web_zip/web_zip_import.dart
//
// Web-only ZIP import pipeline:
// - Pick a .zip file via browser file picker (dart:html)
// - Unzip in-memory
// - Build CpapImportSnapshot: file list (relative path) + PRS1 candidate bytes
//
// Notes:
// - Requires dependency: `archive` (pure Dart, works on Web)
//   Add to pubspec.yaml:
//     dependencies:
//       archive: ^3.6.1

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

import '../../app_state.dart';
import 'zip_picker.dart';

class PickedZip {
  final String name;
  final Uint8List bytes;

  const PickedZip({required this.name, required this.bytes});
}

class WebZipBuildResult {
  final CpapImportSnapshot snapshot;
  final List<CpapImportedFile> allFiles;
  final Map<String, Uint8List> prs1BytesByRelPath;

  const WebZipBuildResult({
    required this.snapshot,
    required this.allFiles,
    required this.prs1BytesByRelPath,
  });
}

class WebZipImport {
  /// Opens browser file picker and reads the selected zip into memory.
  /// Returns null if the user cancels.
  static Future<PickedZip?> pickZipBytes() async {
    if (!kIsWeb) {
      throw UnsupportedError('pickZipBytes is Web-only');
    }
    return ZipPicker.pickZip();
  }

  /// Builds snapshot from zip bytes.
  static WebZipBuildResult buildSnapshotFromZip({
    required Uint8List zipBytes,
    required String zipName,
    required bool Function(String pathLower) isPrs1Candidate,
  }) {
    // Decode ZIP
    final archive = ZipDecoder().decodeBytes(zipBytes, verify: true);

    final allFiles = <CpapImportedFile>[];
    final prs1Bytes = <String, Uint8List>{};

    for (final f in archive.files) {
      if (f.isFile == false) continue;
      final rel = f.name.replaceAll('\\', '/');
      final size = f.size;

      allFiles.add(
        CpapImportedFile(
          absolutePath: 'zip://$zipName/$rel',
          relativePath: rel,
          sizeBytes: size,
        ),
      );

      final lower = rel.toLowerCase();
      if (!isPrs1Candidate(lower)) continue;

      final content = f.content;
      if (content is List<int>) {
        prs1Bytes[rel] = Uint8List.fromList(content);
      } else if (content is Uint8List) {
        prs1Bytes[rel] = content;
      } else {
        // Fallback: archive may give dynamic; try best-effort cast
        prs1Bytes[rel] = Uint8List.fromList(List<int>.from(content as Iterable));
      }
    }

    allFiles.sort((a, b) => a.relativePath.compareTo(b.relativePath));

    final snapshot = CpapImportSnapshot(
      folderPath: 'zip:$zipName',
      allFiles: List.unmodifiable(allFiles),
      prs1BytesByRelPath: Map.unmodifiable(prs1Bytes),
    );

    return WebZipBuildResult(
      snapshot: snapshot,
      allFiles: List.unmodifiable(allFiles),
      prs1BytesByRelPath: Map.unmodifiable(prs1Bytes),
    );
  }
}
