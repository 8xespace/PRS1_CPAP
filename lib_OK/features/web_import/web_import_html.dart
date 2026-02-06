// lib/features/web_import/web_import_html.dart
import 'dart:async';
import 'dart:html' as html;
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
  /// Pick a folder using `<input webkitdirectory>` and:
  /// - return metadata for *all* files (relative path + size)
  /// - read bytes only for PRS1 candidate files (to keep memory sane)
  static Future<WebPickedFolderResult?> pickFolderAndReadPrs1({
    required bool Function(String lowerRelativePath) isPrs1Candidate,
    void Function(int scannedFiles, int totalFiles, int prs1FilesRead)? onProgress,
  }) async {
    final input = html.FileUploadInputElement();
    input.multiple = true;
    input.accept = '';
    input.setAttribute('webkitdirectory', 'true');
    input.setAttribute('directory', 'true');

    final completer = Completer<List<html.File>?>();
    input.onChange.listen((_) {
      completer.complete(input.files);
    });

    // Trigger picker
    input.click();

    final files = await completer.future;
    if (files == null || files.isEmpty) return null;

    // Build file meta list
    final allMetas = <WebPickedFileMeta>[];
    final prs1Bytes = <String, Uint8List>{};

    final total = files.length;
    var scanned = 0;
    var prs1Read = 0;

    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      scanned = i + 1;
      final rel = _relativePathOf(f);
      allMetas.add(WebPickedFileMeta(relativePath: rel, sizeBytes: f.size));

      final lower = rel.toLowerCase();
      if (!isPrs1Candidate(lower)) {
        onProgress?.call(scanned, total, prs1Read);
        continue;
      }

      final bytes = await _readFileBytes(f);
      prs1Bytes[rel] = bytes;
      prs1Read += 1;
      onProgress?.call(scanned, total, prs1Read);
    }

    allMetas.sort((a, b) => a.relativePath.compareTo(b.relativePath));

    final rootName = _guessRootName(allMetas.first.relativePath);
    return WebPickedFolderResult(
      displayName: rootName,
      allFiles: allMetas,
      prs1BytesByRelPath: prs1Bytes,
    );
  }

  static String _relativePathOf(html.File f) {
    try {
      final dyn = f as dynamic;
      final v = dyn.webkitRelativePath as String?;
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    return f.name;
  }

  static String _guessRootName(String relPath) {
    final parts = relPath.split('/');
    if (parts.isEmpty) return '選取資料夾';
    return parts.first.isEmpty ? '選取資料夾' : parts.first;
  }

  static Future<Uint8List> _readFileBytes(html.File f) async {
    final reader = html.FileReader();
    final c = Completer<Uint8List>();

    reader.onError.listen((_) {
      c.completeError(reader.error ?? 'FileReader error');
    });

    reader.onLoadEnd.listen((_) {
      final res = reader.result;
      if (res is ByteBuffer) {
        c.complete(Uint8List.view(res));
      } else if (res is Uint8List) {
        c.complete(res);
      } else {
        // result is typically ByteBuffer
        c.complete(Uint8List.fromList(const []));
      }
    });

    reader.readAsArrayBuffer(f);
    return c.future;
  }
}
