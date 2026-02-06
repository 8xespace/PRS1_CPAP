import 'dart:convert';
import 'dart:io';


class _Sha256 {
  static const List<int> _k = [
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
  ];

  static int _rotr(int x, int n) => ((x >> n) | ((x << (32 - n)) & 0xffffffff)) & 0xffffffff;
  static int _ch(int x, int y, int z) => (x & y) ^ ((~x) & z);
  static int _maj(int x, int y, int z) => (x & y) ^ (x & z) ^ (y & z);
  static int _bsig0(int x) => _rotr(x, 2) ^ _rotr(x, 13) ^ _rotr(x, 22);
  static int _bsig1(int x) => _rotr(x, 6) ^ _rotr(x, 11) ^ _rotr(x, 25);
  static int _ssig0(int x) => _rotr(x, 7) ^ _rotr(x, 18) ^ ((x >> 3) & 0xffffffff);
  static int _ssig1(int x) => _rotr(x, 17) ^ _rotr(x, 19) ^ ((x >> 10) & 0xffffffff);

  static String hexDigest(List<int> data) {
    // Pre-processing
    final bitLen = data.length * 8;
    final msg = List<int>.from(data);
    msg.add(0x80);
    while ((msg.length % 64) != 56) {
      msg.add(0);
    }
    // Append length as 64-bit big endian
    final hi = (bitLen ~/ 0x100000000) & 0xffffffff;
    final lo = bitLen & 0xffffffff;
    msg.addAll([
      (hi >> 24) & 0xff,(hi >> 16) & 0xff,(hi >> 8) & 0xff,hi & 0xff,
      (lo >> 24) & 0xff,(lo >> 16) & 0xff,(lo >> 8) & 0xff,lo & 0xff,
    ]);

    int h0=0x6a09e667, h1=0xbb67ae85, h2=0x3c6ef372, h3=0xa54ff53a,
        h4=0x510e527f, h5=0x9b05688c, h6=0x1f83d9ab, h7=0x5be0cd19;

    final w = List<int>.filled(64, 0);

    for (var i = 0; i < msg.length; i += 64) {
      for (var t = 0; t < 16; t++) {
        final j = i + t*4;
        w[t] = ((msg[j] << 24) | (msg[j+1] << 16) | (msg[j+2] << 8) | msg[j+3]) & 0xffffffff;
      }
      for (var t = 16; t < 64; t++) {
        w[t] = (w[t-16] + _ssig0(w[t-15]) + w[t-7] + _ssig1(w[t-2])) & 0xffffffff;
      }

      var a=h0,b=h1,c=h2,d=h3,e=h4,f=h5,g=h6,h=h7;

      for (var t = 0; t < 64; t++) {
        final t1 = (h + _bsig1(e) + _ch(e,f,g) + _k[t] + w[t]) & 0xffffffff;
        final t2 = (_bsig0(a) + _maj(a,b,c)) & 0xffffffff;
        h=g; g=f; f=e; e=(d + t1) & 0xffffffff;
        d=c; c=b; b=a; a=(t1 + t2) & 0xffffffff;
      }

      h0=(h0+a)&0xffffffff; h1=(h1+b)&0xffffffff; h2=(h2+c)&0xffffffff; h3=(h3+d)&0xffffffff;
      h4=(h4+e)&0xffffffff; h5=(h5+f)&0xffffffff; h6=(h6+g)&0xffffffff; h7=(h7+h)&0xffffffff;
    }

    String toHex(int v) => v.toRadixString(16).padLeft(8,'0');
    return '${toHex(h0)}${toHex(h1)}${toHex(h2)}${toHex(h3)}${toHex(h4)}${toHex(h5)}${toHex(h6)}${toHex(h7)}';
  }
}


/// PRS1 core guard
/// - default: verify core file hashes against manifest
/// - --update: rewrite manifest with current hashes
///
/// Run:
///   dart run tool/prs1_core_guard.dart
///   dart run tool/prs1_core_guard.dart --update
void main(List<String> args) {
  final update = args.contains('--update');

  final manifestFile = File('lib/features/prs1/PRS1_CORE_LOCK_MANIFEST.json');
  if (!manifestFile.existsSync()) {
    stderr.writeln('ERR: manifest not found: ${manifestFile.path}');
    exit(2);
  }

  final manifestJson = jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  final files = (manifestJson['files'] as Map).cast<String, dynamic>();

  final mismatches = <String>[];
  final missing = <String>[];

  final newFiles = <String, String>{};

  for (final path in files.keys) {
    final f = File(path);
    if (!f.existsSync()) {
      missing.add(path);
      continue;
    }
    final bytes = f.readAsBytesSync();
    final hash = _Sha256.hexDigest(bytes);
    newFiles[path] = hash;

    final expected = files[path]?.toString();
    if (expected != hash) {
      mismatches.add(path);
    }
  }

  if (update) {
    final out = <String, dynamic>{
      'version': 1,
      'generated_utc': DateTime.now().toUtc().toIso8601String(),
      'files': newFiles,
    };
    manifestFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
    stdout.writeln('OK: manifest updated (${newFiles.length} files).');
    if (missing.isNotEmpty) {
      stdout.writeln('WARN: missing files were skipped:');
      for (final m in missing) {
        stdout.writeln('  - $m');
      }
    }
    return;
  }

  if (missing.isNotEmpty) {
    stderr.writeln('ERR: missing core files:');
    for (final m in missing) {
      stderr.writeln('  - $m');
    }
    exit(3);
  }

  if (mismatches.isNotEmpty) {
    stderr.writeln('ERR: PRS1 core lock FAILED. Hash mismatches:');
    for (final p in mismatches) {
      stderr.writeln('  - $p');
      stderr.writeln('      expected: ${files[p]}');
      stderr.writeln('      actual:   ${newFiles[p]}');
    }
    stderr.writeln('\nIf you intentionally changed core, run: dart run tool/prs1_core_guard.dart --update');
    exit(1);
  }

  stdout.writeln('OK: PRS1 core lock passed (${files.length} files).');
}
