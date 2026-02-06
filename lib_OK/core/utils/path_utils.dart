// lib/core/utils/path_utils.dart

String joinPath(String a, String b) {
  if (a.endsWith('/') || a.endsWith('\\')) return '$a$b';
  return '$a/$b';
}

String basename(String path) {
  final p = path.replaceAll('\\', '/');
  final idx = p.lastIndexOf('/');
  return idx < 0 ? p : p.substring(idx + 1);
}
