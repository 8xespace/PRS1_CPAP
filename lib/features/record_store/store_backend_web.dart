// lib/features/record_store/store_backend_web.dart
import 'dart:html' as html;

import 'store_backend.dart';

class _WebBackend implements StoreBackend {
  static const _kKey = 'cpap_record_store_v1';

  @override
  Future<String?> loadJson() async {
    return html.window.localStorage[_kKey];
  }

  @override
  Future<void> saveJson(String json) async {
    html.window.localStorage[_kKey] = json;
  }
}

StoreBackend createBackend() => _WebBackend();
