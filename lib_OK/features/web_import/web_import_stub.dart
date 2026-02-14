// lib/features/web_import/web_import_stub.dart
import 'dart:typed_data';

class WebPickedFolderResult {
  final String displayName;
  final List<WebPickedFileMeta> allFiles;
  final Map<String, Uint8List> prs1BytesByRelPath;

  WebPickedFolderResult({
    required this.displayName,
    required this.allFiles,
    required this.prs1BytesByRelPath,
  });
}

class WebPickedFileMeta {
  final String relativePath;
  final int sizeBytes;

  WebPickedFileMeta({required this.relativePath, required this.sizeBytes});
}

class WebImport {
  static Future<WebPickedFolderResult?> pickFolderAndReadPrs1({
    required bool Function(String lowerRelativePath) isPrs1Candidate,
    void Function(int scannedFiles, int totalFiles, int prs1FilesRead)? onProgress,
  }) async {
    return null;
  }
}
