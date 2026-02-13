import 'dart:collection';

/// Very small in-memory cache for expensive chart precomputations.
/// This is **UI-layer** cache (safe to drop at any time).
class Prs1ChartCache<K, V> {
  Prs1ChartCache({this.maxEntries = 64});

  final int maxEntries;
  final _map = LinkedHashMap<K, V>();

  V? get(K key) {
    final v = _map.remove(key);
    if (v != null) {
      // re-insert to mark as most recently used
      _map[key] = v;
    }
    return v;
  }

  void set(K key, V value) {
    if (_map.containsKey(key)) _map.remove(key);
    _map[key] = value;
    while (_map.length > maxEntries) {
      _map.remove(_map.keys.first);
    }
  }

  void clear() => _map.clear();
}
