// lib/features/folder_access/platform/folder_access_platform.dart

import 'package:flutter/foundation.dart';

import 'folder_access_stub.dart';
import 'folder_access_ios.dart';

class FolderAccessResult {
  const FolderAccessResult({required this.granted, this.folderPath, this.bookmarkBase64});

  final bool granted;
  final String? folderPath;

  /// iOS bookmark data (base64) for persistent access.
  final String? bookmarkBase64;
}

abstract class FolderAccessPlatform {
  Future<FolderAccessResult> restoreBookmark();
  Future<FolderAccessResult> pickFolder();
  Future<void> persistBookmark(FolderAccessResult result);

  static FolderAccessPlatform createDefault() {
    if (kIsWeb) return const FolderAccessStub();
    return FolderAccessIOS.orStub();
  }
}
