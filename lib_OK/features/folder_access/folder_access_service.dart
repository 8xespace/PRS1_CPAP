// lib/features/folder_access/folder_access_service.dart

import 'folder_access_state.dart';
import 'platform/folder_access_platform.dart';

class FolderAccessService {
  FolderAccessService(this._platform);

  final FolderAccessPlatform _platform;

  /// Attempt to restore previously granted folder access (iOS security-scoped bookmark).
  Future<bool> restore(FolderAccessState state) async {
    final res = await _platform.restoreBookmark();
    if (res.granted) {
      final p = _normalizePath(res.folderPath);
      state.setGranted(granted: true, folderPath: p);
      return true;
    }
    return false;
  }

  /// Prompt user to pick a folder and persist bookmark (on iOS).
  Future<bool> request(FolderAccessState state) async {
    final res = await _platform.pickFolder();
    if (res.granted) {
      await _platform.persistBookmark(res);
      final p = _normalizePath(res.folderPath);
      state.setGranted(granted: true, folderPath: p);
      return true;
    }
    return false;
  }

  /// iOS native side sometimes returns a file URL string (file:///...).
  /// dart:io expects a plain filesystem path.
  String? _normalizePath(String? folderPath) {
    if (folderPath == null) return null;
    final s = folderPath.trim();
    if (s.isEmpty) return null;

    if (s.startsWith('file://')) {
      try {
        return Uri.parse(s).toFilePath();
      } catch (_) {
        // Fallback: strip scheme.
        return s.replaceFirst(RegExp(r'^file://+'), '/');
      }
    }
    return s;
  }
}
