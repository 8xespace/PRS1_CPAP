// lib/features/record_store/store_backend_stub.dart
import 'store_backend.dart';

class _StubBackend implements StoreBackend {
  const _StubBackend();

  @override
  Future<String?> loadJson() async => null;

  @override
  Future<void> saveJson(String json) async {
    // no-op
  }
}

StoreBackend createBackend() => const _StubBackend();
