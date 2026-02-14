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
      state.setGranted(granted: true, folderPath: res.folderPath);
      return true;
    }
    return false;
  }

  /// Prompt user to pick a folder and persist bookmark (on iOS).
  Future<bool> request(FolderAccessState state) async {
    final res = await _platform.pickFolder();
    if (res.granted) {
      await _platform.persistBookmark(res);
      state.setGranted(granted: true, folderPath: res.folderPath);
      return true;
    }
    return false;
  }
}
