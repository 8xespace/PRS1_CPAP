// lib/features/record_store/store_backend.dart
//
// Simple persistence backend for CPAP record store.
// - Web: uses window.localStorage.
// - Non-web: currently no-op (can be wired to iOS/Android later via MethodChannel or file storage).
//
// IMPORTANT: This module is UI-agnostic and does NOT touch PRS1 decoding logic.

import 'store_backend_stub.dart'
    if (dart.library.html) 'store_backend_web.dart';

abstract class StoreBackend {
  Future<String?> loadJson();
  Future<void> saveJson(String json);
}

StoreBackend createStoreBackend() => createBackend();
