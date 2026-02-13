// lib/features/folder_access/platform/folder_access_stub.dart

import 'folder_access_platform.dart';

class FolderAccessStub implements FolderAccessPlatform {
  const FolderAccessStub();

  @override
  Future<FolderAccessResult> restoreBookmark() async {
    return const FolderAccessResult(granted: false);
  }

  @override
  Future<FolderAccessResult> pickFolder() async {
    return const FolderAccessResult(granted: false);
  }

  @override
  Future<void> persistBookmark(FolderAccessResult result) async {}
}
