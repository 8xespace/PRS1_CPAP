// lib/features/folder_access/folder_access_state.dart

import 'package:flutter/foundation.dart';

class FolderAccessState extends ChangeNotifier {
  bool _isGranted = false;
  String? _folderPath;

  bool get isGranted => _isGranted;
  String? get folderPath => _folderPath;

  void setGranted({required bool granted, String? folderPath}) {
    _isGranted = granted;
    _folderPath = folderPath;
    notifyListeners();
  }

  void clear() {
    _isGranted = false;
    _folderPath = null;
    notifyListeners();
  }
}
