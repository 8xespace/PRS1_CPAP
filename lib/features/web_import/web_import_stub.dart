// lib/features/web_import/web_import_stub.dart
import 'dart:typed_data';

class WebPickedFolderHandle {
  WebPickedFolderHandle();
}

class WebPickedFolderResult {
  final String displayName;
  final List<WebPickedFileMeta> allFiles;
  final Map<String, Uint8List> prs1HeadBytesByRelPath;
  final WebPickedFolderHandle handle;

  WebPickedFolderResult({
    required this.displayName,
    required this.allFiles,
    required this.prs1HeadBytesByRelPath,
    required this.handle,
  });
}

class WebPickedFileMeta {
  final String relativePath;
  final int sizeBytes;

  WebPickedFileMeta({required this.relativePath, required this.sizeBytes});
}

class WebImport {
  static Future<WebPickedFolderResult?> pickFolderAndReadPrs1Heads({
    required bool Function(String lowerRelativePath) isPrs1Candidate,
    int headMaxBytes = 512,
    void Function(int scannedFiles, int totalFiles, int prs1HeadsRead)? onProgress,
  }) async {
    return null;
  }

  static Future<Map<String, Uint8List>> readFullBytesFor({
    required WebPickedFolderHandle handle,
    required Iterable<String> relativePaths,
    void Function(int done, int total)? onProgress,
  }) async {
    return <String, Uint8List>{};
  }
}
