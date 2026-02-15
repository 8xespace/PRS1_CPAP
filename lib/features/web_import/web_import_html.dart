// lib/features/web_import/web_import_html.dart
import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

/// Opaque handle that keeps the picked File objects so we can read them in stages (head -> full).
class WebPickedFolderHandle {
  WebPickedFolderHandle(this._filesByRelPath);

  final Map<String, html.File> _filesByRelPath;

  html.File? fileOf(String relPath) => _filesByRelPath[relPath];
}

class WebPickedFolderResult {
  final String displayName;
  final List<WebPickedFileMeta> allFiles;

  /// Only PRS1 candidate files' head bytes (0..N) keyed by relative path.
  final Map<String, Uint8List> prs1HeadBytesByRelPath;

  /// Handle to later read full bytes for a subset of files.
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
  /// Pick a folder using `<input webkitdirectory>` and:
  /// - return metadata for *all* files (relative path + size)
  /// - read only the HEAD bytes (0..[headMaxBytes]) for PRS1 candidate files
  ///
  /// This is designed for Phase 1 "Header 準濾" on Web to avoid loading the entire SD card into memory.
  static Future<WebPickedFolderResult?> pickFolderAndReadPrs1Heads({
    required bool Function(String lowerRelativePath) isPrs1Candidate,
    int headMaxBytes = 512,
    void Function(int scannedFiles, int totalFiles, int prs1HeadsRead)? onProgress,
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

    final allMetas = <WebPickedFileMeta>[];
    final headBytes = <String, Uint8List>{};
    final filesByRel = <String, html.File>{};

    final total = files.length;
    var prs1HeadsRead = 0;

    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      final rel = _relativePathOf(f);
      allMetas.add(WebPickedFileMeta(relativePath: rel, sizeBytes: f.size));

      final lower = rel.toLowerCase();
      if (isPrs1Candidate(lower)) {
        filesByRel[rel] = f;
        final bytes = await _readFileSliceBytes(f, 0, headMaxBytes);
        headBytes[rel] = bytes;
        prs1HeadsRead += 1;
      }

      onProgress?.call(i + 1, total, prs1HeadsRead);
    }

    allMetas.sort((a, b) => a.relativePath.compareTo(b.relativePath));

    final rootName = _guessRootName(allMetas.first.relativePath);
    return WebPickedFolderResult(
      displayName: rootName,
      allFiles: allMetas,
      prs1HeadBytesByRelPath: headBytes,
      handle: WebPickedFolderHandle(filesByRel),
    );
  }

  /// Read full bytes for the specified [relativePaths] that exist in [handle].
  static Future<Map<String, Uint8List>> readFullBytesFor({
    required WebPickedFolderHandle handle,
    required Iterable<String> relativePaths,
    void Function(int done, int total)? onProgress,
  }) async {
    final out = <String, Uint8List>{};
    final list = relativePaths.toList(growable: false);
    final total = list.length;
    for (var i = 0; i < list.length; i++) {
      final rel = list[i];
      final f = handle.fileOf(rel);
      if (f == null) continue;
      final bytes = await _readFileBytes(f);
      out[rel] = bytes;
      onProgress?.call(i + 1, total);
    }
    return out;
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
        c.complete(Uint8List.fromList(const []));
      }
    });

    reader.readAsArrayBuffer(f);
    return c.future;
  }

  static Future<Uint8List> _readFileSliceBytes(html.File f, int start, int maxBytes) async {
    // html.File.slice(end) is end-exclusive; guard against tiny files.
    final end = (start + maxBytes) > f.size ? f.size : (start + maxBytes);
    final slice = f.slice(start, end);

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
        c.complete(Uint8List.fromList(const []));
      }
    });

    reader.readAsArrayBuffer(slice);
    return c.future;
  }
}
