// lib/features/folder_access/platform/folder_access_ios.dart

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

import 'folder_access_platform.dart';
import 'folder_access_stub.dart';

/// iOS implementation via MethodChannel.
///
/// Notes:
/// - You will implement the iOS side in Runner/AppDelegate.swift.
/// - The channel methods are placeholders and can be wired later:
///   - restoreBookmark() -> {granted: bool, path: String?}
///   - pickFolder() -> {granted: bool, path: String?, bookmark: String?}
///   - persistBookmark(bookmark: String)
class FolderAccessIOS implements FolderAccessPlatform {
  FolderAccessIOS();

  static const MethodChannel _ch = MethodChannel('cpap.folder_access');

  static FolderAccessPlatform orStub() {
    // Web has no access to iOS security-scoped bookmarks.
    if (kIsWeb) return const FolderAccessStub();
    // Avoid dart:io Platform on web; use Flutter's TargetPlatform.
    if (defaultTargetPlatform != TargetPlatform.iOS) return const FolderAccessStub();
    return FolderAccessIOS();
  }

  @override
  Future<FolderAccessResult> restoreBookmark() async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('restoreBookmark');
      final granted = (m?['granted'] as bool?) ?? false;
      final path = m?['path'] as String?;
      return FolderAccessResult(granted: granted, folderPath: path);
    } catch (_) {
      return const FolderAccessResult(granted: false);
    }
  }

  @override
  Future<FolderAccessResult> pickFolder() async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('pickFolder');
      final granted = (m?['granted'] as bool?) ?? false;
      final path = m?['path'] as String?;
      final bookmark = m?['bookmark'] as String?;
      return FolderAccessResult(granted: granted, folderPath: path, bookmarkBase64: bookmark);
    } catch (_) {
      return const FolderAccessResult(granted: false);
    }
  }

  @override
  Future<void> persistBookmark(FolderAccessResult result) async {
    final b64 = result.bookmarkBase64;
    if (b64 == null || b64.isEmpty) return;
    try {
      await _ch.invokeMethod<void>('persistBookmark', {'bookmark': b64});
    } catch (_) {
      // swallow
    }
  }
}
