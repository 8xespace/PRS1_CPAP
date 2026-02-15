// lib/home/home_page.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../features/folder_access/folder_access_service.dart';
import '../features/folder_access/folder_access_state.dart';
import '../features/folder_access/platform/folder_access_ios.dart';
import '../features/prs1/decode/prs1_loader.dart';
import '../features/prs1/index/prs1_header_index.dart';
import '../features/prs1/index/prs1_range_gate.dart';
import '../features/prs1/model/prs1_event.dart';
import '../features/prs1/model/prs1_session.dart';
import '../features/prs1/model/prs1_breath.dart';
import '../features/prs1/model/prs1_waveform_channel.dart';
import '../features/prs1/model/prs1_signal_sample.dart';
import '../features/prs1/aggregate/prs1_daily_aggregator.dart';
import '../features/prs1/aggregate/prs1_trend_aggregator.dart';
import '../features/prs1/prs1_reader.dart';
import '../features/web_import/web_import.dart';
import '../features/local_fs/local_fs.dart';
import '../features/web_zip/web_zip_import.dart';
import '../features/record_store/cpap_record_store.dart';
import 'bottom_controls_bar.dart';
import 'home_header.dart';
import 'prs1_dashboard_page.dart';
import '../features/prs1/waveform/prs1_waveform_index.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const bool _enablePrs1Logs = false; // set true to re-enable debug logs

  // Lightweight logger shims (some patches emit logW/logD from within HomePage).
  // Keeping them local avoids adding cross-module dependencies.
  void logW(String msg) {
    if (!_enablePrs1Logs) return;
    // ignore: avoid_print
    print('[W] $msg');
  }

  void logD(String msg) {
    if (!_enablePrs1Logs) return;
    // ignore: avoid_print
    print('[D] $msg');
  }

  final FolderAccessState _folderState = FolderAccessState();
  late final FolderAccessService _folderService;

  final ScrollController _noticeScrollCtrl = ScrollController();

  bool _busy = false;
  String _status = '尚未讀取';
  int _fileCount = 0;
  int _prs1BlobCount = 0;

  // UI progress for the *scan/read* phase (mainly for Web folder picker).
  int _scanDone = 0;
  int _scanTotal = 0;

  // Engine phase UX: show a clear hint when scan is done but the compute engine is running.
  DateTime? _computingSince;
  static const Duration _minComputingHint = Duration(milliseconds: 1200);

  Future<void> _enterComputingPhase(AppState appState) async {
    _computingSince = DateTime.now();
    appState.setEnginePhase(
      EnginePhase.computing,
      message: '統計引擎運作中，請不要關閉本軟體',
    );
    // Yield one frame so the hint can paint before heavy synchronous work starts.
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }

  Future<void> _leaveComputingPhaseIfNeeded(AppState appState) async {
    final since = _computingSince;
    if (since == null) return;
    final elapsed = DateTime.now().difference(since);
    if (elapsed < _minComputingHint) {
      await Future<void>.delayed(_minComputingHint - elapsed);
    }
    _computingSince = null;
    // Caller will set next phase.
  }


  @override
  void initState() {
    super.initState();
    _folderService = FolderAccessService(FolderAccessIOS.orStub());

    // Best-effort restore previous iOS bookmark.
    _folderService.restore(_folderState).then((ok) {
      if (!mounted) return;
      if (ok && _folderState.folderPath != null) {
        setState(() {
          _status = '已恢復授權：${_folderState.folderPath}';
        });
      }
    });
  }

  @override
  void dispose() {
    _folderState.dispose();
    super.dispose();    _noticeScrollCtrl.dispose();

  }

  bool _isPrs1Candidate(String pathLower) {
    // PRS1/DreamStation data files frequently use numeric 3-digit extensions:
    // .000, .001, ... .999 (OSCAR handles many of them, not just 0-2).
    // We also keep a few known sidecar formats.
    if (RegExp(r'\.\d{3}$').hasMatch(pathLower)) return true;
    return pathLower.endsWith('.edf') ||
        pathLower.endsWith('.tgt') ||
        pathLower.endsWith('.dat');
  }

  String _toRelPath({required String root, required String absPath}) {
    final normRoot = root.replaceAll('\\', '/');
    final normAbs = absPath.replaceAll('\\', '/');
    if (normAbs.startsWith(normRoot)) {
      var rel = normAbs.substring(normRoot.length);
      while (rel.startsWith('/')) {
        rel = rel.substring(1);
      }
      return rel.isEmpty ? '.' : rel;
    }
    return normAbs;
  }

  Future<void> _importZipAndParseWeb() async {
    // NOTE: Despite the name, Web now uses *folder picker* (webkitdirectory),
    // because large ZIP uploads/unzips are too slow and memory heavy in browsers.
    if (!kIsWeb) return;
    if (_busy) return;

    setState(() {
      _busy = true;
      _status = '等待使用者選擇資料夾...';
      _fileCount = 0;
      _prs1BlobCount = 0;
      _scanDone = 0;
      _scanTotal = 0;
    });

    // Phase: scanning / reading files.
    appStateStore.setEnginePhase(EnginePhase.scanning, message: '讀取資料中...');

    try {
      final WebPickedFolderResult? picked = await WebImport.pickFolderAndReadPrs1Heads(
        isPrs1Candidate: _isPrs1Candidate,
        headMaxBytes: 512,
        onProgress: (scanned, total, prs1HeadsRead) {
          if (!mounted) return;
          setState(() {
            _scanDone = scanned;
            _scanTotal = total;
            _status = '讀取中...（檔案 $total / PRS1頭部 $prs1HeadsRead）';
          });
        },
      );

      if (!mounted) return;
      if (picked == null) {
        appStateStore.setEnginePhase(EnginePhase.idle);
        setState(() {
          _busy = false;
          _status = '已取消資料夾選擇';
        });
        return;
      }

      final pickedResult = picked;

      // Scan/read progress is done. Switch to compute phase and show UX hint.
      await _enterComputingPhase(appStateStore);

      setState(() {
        _status = '已取得檔案清單（${pickedResult.allFiles.length}）... 開始解析（PRS1檔案: ${pickedResult.prs1HeadBytesByRelPath.length}）...';
        _fileCount = pickedResult.allFiles.length;
        _prs1BlobCount = pickedResult.prs1HeadBytesByRelPath.length;
      });// ---------------- Phase 1: Header 準濾 + 35 天 RangeGate (Web) ----------------
      // Web 必須避免「先把整張 SD 的所有 PRS1 檔案完整讀入記憶體」。
      // 因此流程改為：
      //  1) 先讀每個候選檔的 head(0..N) -> 建 HeaderIndex
      //  2) 推導 lastUsedDate -> 建 35 天 RangeGate
      //  3) 只對通過 gate 的檔案做 full read -> 才進 full decode

      final sizeByRel = <String, int>{};
      for (final meta in pickedResult.allFiles) {
        sizeByRel[meta.relativePath] = meta.sizeBytes;
      }

      final headerIndex = Prs1HeaderIndex.buildFromHeads(
        headBytesByRelPath: pickedResult.prs1HeadBytesByRelPath,
        sizeBytesByRelPath: sizeByRel,
      );

      DateTime lastUsed = headerIndex.lastUsedDateLocal ?? DateTime.now();
      if (headerIndex.lastUsedDateLocal == null) {
        logW('PRS1 Phase1(Web): lastUsedDate 推導失敗（無可用 header timestamp）；暫以 now 作為 lastUsedDate，並保守允許所有檔案。');
      }

      final gate = Prs1RangeGate(
        allowedStart: lastUsed.subtract(const Duration(days: 35)),
        allowedEnd: lastUsed,
      );

      int allowed = 0;
      int skipped = 0;
      final allowedRel = <String>{};

      for (final e in headerIndex.entries) {
        final t = e.timestampLocal;
        final ok = (t == null) ? true : gate.isAllowed(t);
        if (ok) {
          allowedRel.add(e.relativePath);
          allowed++;
        } else {
          skipped++;
        }
      }

      // ignore: avoid_print
      if (_enablePrs1Logs) print('[PRS1][Phase1][Web] lastUsedDate=$lastUsed');
      // ignore: avoid_print
      if (_enablePrs1Logs) print('[PRS1][Phase1][Web] allowedStart=${gate.allowedStart} allowedEnd=${gate.allowedEnd}');
      // ignore: avoid_print
      if (_enablePrs1Logs) print('[PRS1][Phase1][Web] allowedFiles=$allowed skippedFiles=$skipped (unknownTimestamp treated as allowed)');

      // Full-read only for allowed files.
      if (mounted) {
        setState(() {
          _status = 'Phase1 準濾：允許 $allowed / ${headerIndex.entries.length} 檔... 讀取通過 gate 的檔案 bytes 中...';
        });
      }

      final filteredPrs1Bytes = await WebImport.readFullBytesFor(
        handle: pickedResult.handle,
        relativePaths: allowedRel,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _status = '讀取通過 gate 的檔案 bytes 中...（$done / $total）';
          });
        },
      );

      if (mounted) {
        setState(() {
          _prs1BlobCount = filteredPrs1Bytes.length;
          _status = 'Phase1 準濾：允許 ${filteredPrs1Bytes.length} 檔，開始解析...';
        });
      }


      final loader = Prs1Loader();
      final sessions = <Prs1Session>[];

      int _prs1ParseFailures = 0;
      for (final e in filteredPrs1Bytes.entries) {
        try {
          final res = loader.parse(e.value, sourcePath: e.key);
          if (res.sessions.isNotEmpty) sessions.addAll(res.sessions);
        } catch (err, st) {
          _prs1ParseFailures++;
          logW('PRS1 parse failed: ${e.key} => $err');
          logD('$st');
          // Keep going; a few corrupt/unsupported chunks should not block the UI.
        }
      }

      // PRS1 SD card data usually spreads one therapy session across multiple files
      // (e.g. .005 contains usage/duration, .002 contains per-interval signals).
      // If we don't merge them, daily aggregation can't see leak/pressure samples
      // alongside usage.
      final mergedSessions = _mergePrs1Sessions(sessions);

      mergedSessions.sort((a, b) => b.start.compareTo(a.start));

      if (mergedSessions.isNotEmpty) {
        final newestS = mergedSessions.first.start;
        final oldestS = mergedSessions.last.start;
        final spanDays = newestS.difference(oldestS).inDays + 1;
        // ignore: avoid_print
        if (_enablePrs1Logs) print('[PRS1][Phase1][Web] sessions spanDays=$spanDays (newest=$newestS oldest=$oldestS)');
      } else {
        // ignore: avoid_print
        if (_enablePrs1Logs) print('[PRS1][Phase1][Web] sessions=0');
      }

      // Web「資訊流控制」：避免一次對整張 SD 進行全量 detail 建索引而卡死。
      // 解析 sessions（summary）仍保留全量；但 detail（indices/buckets）僅先建立「最近 N 天」，
      // 以支援儀表板與近期趨勢。需要全量時再另行觸發（後續會加按鈕/策略）。
      const int _webDetailDays = 35; // safety cap: 5 weeks (35 days)
      final DateTime? newest = mergedSessions.isEmpty ? null : mergedSessions.first.start;
      final DateTime? cutoff =
          newest == null ? null : newest.subtract(const Duration(days: _webDetailDays));

      final List<Prs1Session> detailSessions = (cutoff == null)
          ? mergedSessions
          : mergedSessions.where((s) => s.start.isAfter(cutoff)).toList();

      if (!mounted) return;
      setState(() {
        _status =
            'Detail: building indices/buckets（Web 加速：最近 $_webDetailDays 天，sessions ${detailSessions.length}/${mergedSessions.length}）';
      });

      // Milestone G: Build waveform index (viewport-ready)
      final waveformIndex = Prs1WaveformIndex.build(detailSessions);

      // Layer 6: Daily Aggregation Engine (OSCAR-style buckets)
      final dailyBuckets = Prs1DailyAggregator().build(detailSessions);
      // Layer 7: Weekly / Monthly trend buckets
      final trendAgg = const Prs1TrendAggregator();
      final weeklyBuckets = trendAgg.buildWeekly(dailyBuckets);
      final monthlyBuckets = trendAgg.buildMonthly(dailyBuckets);


      // Build snapshot compatible with AppState
      final allFiles = pickedResult.allFiles
          .map((m) => CpapImportedFile(
                absolutePath: '(web)',
                relativePath: m.relativePath,
                sizeBytes: m.sizeBytes,
              ))
          .toList();

      final snapshot = CpapImportSnapshot(
        folderPath: 'web-folder:${pickedResult.displayName}',
        allFiles: allFiles,
        prs1BytesByRelPath: filteredPrs1Bytes,
      );

      final appState = appStateStore;
      appState.setImportSnapshot(snapshot);
      appState.setPrs1Sessions(mergedSessions);
      appState.setPrs1WaveformIndex(waveformIndex.isEmpty ? null : waveformIndex);
      appState.setPrs1DailyBuckets(dailyBuckets);
      appState.setPrs1WeeklyBuckets(weeklyBuckets);
      appState.setPrs1MonthlyBuckets(monthlyBuckets);

      // Persist minimal continuity stats (web: localStorage; iOS/Android: stubbed until native wiring).
      await CpapRecordStore.I.upsertFromEngine(
        folderPath: snapshot.folderPath,
        dailyBuckets: dailyBuckets,
        sessions: mergedSessions,
      );


      await _leaveComputingPhaseIfNeeded(appStateStore);

      if (!mounted) return;
      appStateStore.setEnginePhase(EnginePhase.done);
      setState(() {
        _busy = false;
        _status = '完成';
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('匯入完成：睡眠場次 ${mergedSessions.length}')),
        );
      }

      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const Prs1DashboardPage()),
        );
      }
    } catch (e) {
      if (!mounted) return;
      appStateStore.setEnginePhase(EnginePhase.error, message: 'Web 匯入失敗：$e');
      setState(() {
        _busy = false;
        _status = 'Web 匯入失敗：$e';
      });
    }
  }

  Future<void> _readFolderAndParse() async {
    // Web: keep existing import pipeline (folder picker / ZIP) unchanged.
    if (kIsWeb) {
      await _importZipAndParseWeb();
      return;
    }

    if (_busy) return;

    setState(() {
      _busy = true;
      _status = '等待使用者選取資料夾...';
      _fileCount = 0;
      _prs1BlobCount = 0;
    });

    appStateStore.setEnginePhase(EnginePhase.scanning, message: '掃描/讀取資料中...');

    final ok = await _folderService.request(_folderState);
    final folderPath = _folderState.folderPath;

    if (!mounted) return;

    if (!ok || folderPath == null || folderPath.isEmpty) {
      appStateStore.setEnginePhase(EnginePhase.idle);
      setState(() {
        _busy = false;
        _status = '已取消或未授權資料夾';
      });
      return;
    }

    await _parseFolderPath(folderPath);
  }

  /// iOS「第二個開啟功能」：優先使用已恢復/已授權的資料夾（security-scoped bookmark）。
  /// - 不會覆蓋 Web 流程（Web 仍走原本匯入）
  /// - 若尚未授權，會提示使用者改按「讀取記憶卡」重新選取
  Future<void> _openGrantedFolderAndParse() async {
    if (kIsWeb) {
      // Web 不支援 security-scoped bookmark；保持原有流程即可。
      await _importZipAndParseWeb();
      return;
    }
    if (_busy) return;

    setState(() {
      _busy = true;
      _status = '嘗試開啟已授權資料夾...';
      _fileCount = 0;
      _prs1BlobCount = 0;
    });

    appStateStore.setEnginePhase(EnginePhase.scanning, message: '掃描/讀取資料中...');

    final ok = await _folderService.restore(_folderState);
    final folderPath = _folderState.folderPath;

    if (!mounted) return;

    if (!ok || folderPath == null || folderPath.isEmpty) {
      appStateStore.setEnginePhase(EnginePhase.idle);
      setState(() {
        _busy = false;
        _status = '尚未授權資料夾（請改按「讀取記憶卡」選取一次）';
      });
      return;
    }

    await _parseFolderPath(folderPath);
  }

  Future<void> _parseFolderPath(String folderPath) async {
    try {
      setState(() {
        _status = '掃描檔案中...';
      });

      final entries = await LocalFs.listFilesRecursive(folderPath);

      final allFiles = <CpapImportedFile>[];
      final prs1Bytes = <String, Uint8List>{};

      for (final ent in entries) {
        allFiles.add(
          CpapImportedFile(
            absolutePath: ent.absolutePath,
            relativePath: ent.relativePath,
            sizeBytes: ent.size,
          ),
        );
      }

      allFiles.sort((a, b) => a.relativePath.compareTo(b.relativePath));


      setState(() {
        _fileCount = allFiles.length;
        _status = '已取得檔案清單（${allFiles.length}）... 讀取 PRS1 檔案 bytes 中...';
      });

      // ---------------- Phase 1: Header 準濾 + 35 天 RangeGate ----------------
      // 1) 先只讀取每個 PRS1 候選檔的前段 header（小於 1KB），建立 HeaderIndex。
      // 2) 推導 lastUsedDate。
      // 3) 建立 RangeGate(35 days)，並且「只讀入」允許範圍內的檔案 bytes。

      const int _headerMaxBytes = 512; // EDF header needs 184+, PRS1 chunk needs 15+.

      final Map<String, Uint8List> heads = <String, Uint8List>{};
      final Map<String, int> sizeByRel = <String, int>{};

      for (final f in allFiles) {
        final pl = f.relativePath.toLowerCase();
        if (!_isPrs1Candidate(pl)) continue;
        sizeByRel[f.relativePath] = f.sizeBytes;
        // Head-only read (Phase 1)
        final head = await LocalFs.readHead(f.absolutePath, _headerMaxBytes);
        heads[f.relativePath] = head;
      }

      final headerIndex = Prs1HeaderIndex.buildFromHeads(
        headBytesByRelPath: heads,
        sizeBytesByRelPath: sizeByRel,
      );

      DateTime lastUsed =
          headerIndex.lastUsedDateLocal ?? DateTime.now();
      if (headerIndex.lastUsedDateLocal == null) {
        logW('PRS1 Phase1: lastUsedDate 推導失敗（無可用 header timestamp）；暫以 now 作為 lastUsedDate，並保守允許所有檔案。');
      }

      final gate = Prs1RangeGate(
        allowedStart: lastUsed.subtract(const Duration(days: 35)),
        allowedEnd: lastUsed,
      );

      int allowed = 0;
      int skipped = 0;
      final allowedRel = <String>{};

      for (final e in headerIndex.entries) {
        final t = e.timestampLocal;
        // Strict when timestamp is known; conservative allow when unknown.
        final ok = (t == null) ? true : gate.isAllowed(t);
        if (ok) {
          allowedRel.add(e.relativePath);
          allowed++;
        } else {
          skipped++;
        }
      }

      // Web Debug 檢核點：console 印出
      // - lastUsedDate
      // - allowed start/end
      // - skipped / allowed counts
      // ignore: avoid_print
      if (_enablePrs1Logs) print('[PRS1][Phase1] lastUsedDate=$lastUsed');
      // ignore: avoid_print
      if (_enablePrs1Logs) print('[PRS1][Phase1] allowedStart=${gate.allowedStart} allowedEnd=${gate.allowedEnd}');
      // ignore: avoid_print
      if (_enablePrs1Logs) print('[PRS1][Phase1] allowedFiles=$allowed skippedFiles=$skipped (unknownTimestamp treated as allowed)');

      // 只把「允許範圍內」的 PRS1 檔讀進記憶體（避免整張卡全部吃進來）
      for (final f in allFiles) {
        final pl = f.relativePath.toLowerCase();
        if (!_isPrs1Candidate(pl)) continue;
        if (!allowedRel.contains(f.relativePath)) continue;
        final bytes = await LocalFs.readBytes(f.absolutePath);
        prs1Bytes[f.relativePath] = Uint8List.fromList(bytes);
      }


      setState(() {
        _prs1BlobCount = prs1Bytes.length;
        _status = '開始解析（PRS1檔案: ${prs1Bytes.length}）...';
      });

      await _enterComputingPhase(appStateStore);

      // 解析：把每個 blob 丟進 loader，收集 session
      final loader = Prs1Loader();
      final sessions = <Prs1Session>[];

      for (final e in prs1Bytes.entries) {
        final res = loader.parse(e.value, sourcePath: e.key);
        if (res.sessions.isNotEmpty) {
          sessions.addAll(res.sessions);
        }
      }

      final mergedSessions = _mergePrs1Sessions(sessions);
      mergedSessions.sort((a, b) => b.start.compareTo(a.start));

      if (mergedSessions.isNotEmpty) {
        final newestS = mergedSessions.first.start;
        final oldestS = mergedSessions.last.start;
        final spanDays = newestS.difference(oldestS).inDays + 1;
        // ignore: avoid_print
        if (_enablePrs1Logs) print('[PRS1][Phase1] sessions spanDays=$spanDays (newest=$newestS oldest=$oldestS)');
      } else {
        // ignore: avoid_print
        if (_enablePrs1Logs) print('[PRS1][Phase1] sessions=0');
      }

      // Web「資訊流控制」：避免一次對整張 SD 進行全量 detail 建索引而卡死。
      // 解析 sessions（summary）仍保留全量；但 detail（indices/buckets）僅先建立「最近 N 天」，
      // 以支援儀表板與近期趨勢。需要全量時再另行觸發（後續會加按鈕/策略）。
      const int _webDetailDays = 35; // safety cap: 5 weeks (35 days)
      final DateTime? newest = mergedSessions.isEmpty ? null : mergedSessions.first.start;
      final DateTime? cutoff =
          newest == null ? null : newest.subtract(const Duration(days: _webDetailDays));

      final List<Prs1Session> detailSessions = (cutoff == null)
          ? mergedSessions
          : mergedSessions.where((s) => s.start.isAfter(cutoff)).toList();

      if (!mounted) return;
      setState(() {
        _status =
            'Detail: building indices/buckets（Web 加速：最近 $_webDetailDays 天，sessions ${detailSessions.length}/${mergedSessions.length}）';
      });

      // Milestone G: Build waveform index (viewport-ready)
      final waveformIndex = Prs1WaveformIndex.build(detailSessions);

      // Layer 6: Daily Aggregation Engine (OSCAR-style buckets)
      final dailyBuckets = Prs1DailyAggregator().build(detailSessions);
      // Layer 7: Weekly / Monthly trend buckets
      final trendAgg = const Prs1TrendAggregator();
      final weeklyBuckets = trendAgg.buildWeekly(dailyBuckets);
      final monthlyBuckets = trendAgg.buildMonthly(dailyBuckets);


      final appState = appStateStore;

      // Snapshot: 檔案清單 + 相對路徑 + PRS1 bytes（給第 3 層用）
      appState.setImportSnapshot(
        CpapImportSnapshot(
          folderPath: folderPath,
          allFiles: List.unmodifiable(allFiles),
          prs1BytesByRelPath: Map.unmodifiable(prs1Bytes),
        ),
      );

      // Parsed sessions（第 3 層儀表板用）
      appState.setPrs1Sessions(mergedSessions);
      appState.setPrs1WaveformIndex(waveformIndex.isEmpty ? null : waveformIndex);
      appState.setPrs1DailyBuckets(dailyBuckets);
      appState.setPrs1WeeklyBuckets(weeklyBuckets);
      appState.setPrs1MonthlyBuckets(monthlyBuckets);

      // Persist minimal continuity stats (web: localStorage; iOS/Android: stubbed until native wiring).
      await CpapRecordStore.I.upsertFromEngine(
        folderPath: folderPath,
        dailyBuckets: dailyBuckets,
        sessions: mergedSessions,
      );


      await _leaveComputingPhaseIfNeeded(appStateStore);

      if (!mounted) return;
      appStateStore.setEnginePhase(EnginePhase.done);
      setState(() {
        _busy = false;
        _status = '完成';
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('讀取完成：睡眠場次 ${mergedSessions.length}')),
        );
      }

      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const Prs1DashboardPage()),
        );
      }
    } catch (e) {
      if (!mounted) return;

      // Give a more actionable message for iOS folder permission issues.
      var msg = '發生錯誤：$e';

      // Web/Chrome 不會有 iOS 的資料夾授權問題；iOS 只要遇到「選得到但掃不到」，
      // 幾乎都是 security-scoped + sandbox 路徑問題，因此直接給出可操作的提示即可。
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        msg = '讀取資料夾失敗（iOS 權限/路徑問題）：$e\n\n建議：iOS 上必須使用「安全性範圍資料夾（security-scoped）」授權，並在 native 端把選取的資料夾複製到 App sandbox 後再讓 Flutter 掃描。';
      }

      appStateStore.setEnginePhase(EnginePhase.error, message: msg);
      setState(() {
        _busy = false;
        _status = msg;
      });
    }
  }

@override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final appState = appStateStore;
    final snap = appState.importSnapshot;

    return Scaffold(
      backgroundColor: Color.alphaBlend(cs.surfaceVariant.withOpacity(0.35), cs.surface),
      body: SafeArea(
        child: Column(
          children: [
            const HomeHeader(
              titleText: '讀取睡眠呼吸紀錄',
              showBack: false,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 860),
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                    color: Color.alphaBlend(cs.surfaceVariant.withOpacity(0.45), cs.surface),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: cs.outlineVariant.withOpacity(0.35),
                      width: 1,
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '01. 請點擊「讀取記憶卡」，將位置指向陽壓呼吸器的記憶卡或是裝置中的指定目錄。\n'
                        '02. 讀取完整檔案、進入統計引擎皆需要相當的運作時間，敬請您耐心等候。\n'
                        '03. 本應用程式僅支援 Philips DreamStation 系列陽壓呼吸治療器檔案規格。',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 14),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final isWide = constraints.maxWidth >= 600;
                          final bigHeight = isWide ? 90.0 : 84.0;
                          final showScanProgress = _busy && _scanTotal > 0;
                          final progressValue = showScanProgress
                              ? (_scanDone <= 0
                                  ? 0.0
                                  : (_scanDone / _scanTotal).clamp(0.0, 1.0))
                              : null;

                          final readBtn = FilledButton.icon(
                            onPressed: _busy ? null : _readFolderAndParse,
                            style: FilledButton.styleFrom(
                              minimumSize: Size.fromHeight(bigHeight),
                              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              textStyle: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.2,
                              ),
                            ),
                            icon: _busy
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(strokeWidth: 2.2),
                                  )
                                : Icon(kIsWeb ? Icons.upload_file : Icons.sd_card, size: 24),
                            label: Text(_busy ? '讀取中...' : '讀取記憶卡'),
                          );

                          final recordsBtn = OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () {
                                    if (appState.prs1Sessions.isEmpty) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('尚未載入資料，請先讀取記憶卡。')),
                                      );
                                      return;
                                    }
                                    Navigator.of(context).push(
                                      MaterialPageRoute(builder: (_) => const Prs1DashboardPage()),
                                    );
                                  },
                            style: OutlinedButton.styleFrom(
                              minimumSize: Size.fromHeight(bigHeight),
                              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              textStyle: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.2,
                              ),
                              side: BorderSide(
                                color: cs.primary.withOpacity(0.40),
                                width: 1.6,
                              ),
                            ),
                            icon: const Icon(Icons.history, size: 24),
                            label: const Text('我的紀錄'),
                          );

                          final isIOS = (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);


                          final buttons = isIOS
                              ? (isWide
                                  ? Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(child: readBtn),
                                          ],
                                        ),
                                        const SizedBox(height: 10),
                                        recordsBtn,
                                      ],
                                    )
                                  : Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        readBtn,
                                        const SizedBox(height: 10),
                                        recordsBtn,
                                      ],
                                    ))
                              : (isWide
                                  ? Row(
                                      children: [
                                        Expanded(child: readBtn),
                                        const SizedBox(width: 10),
                                        Expanded(child: recordsBtn),
                                      ],
                                    )
                                  : Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        readBtn,
                                        const SizedBox(height: 10),
                                        recordsBtn,
                                      ],
                                    ));

                          // 進度條（與狀態列等寬，並做響應式：
                          // - 窄版：僅顯示條
                          // - 寬版：右側附百分比
                          final progressBar = (!showScanProgress)
                              ? const SizedBox.shrink()
                              : (isWide
                                  ? Row(
                                      children: [
                                        Expanded(
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(8),
                                            child: LinearProgressIndicator(
                                              minHeight: 12,
                                              value: progressValue,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        SizedBox(
                                          width: 56,
                                          child: Text(
                                            '${(progressValue! * 100).round()}%',
                                            textAlign: TextAlign.right,
                                            style: theme.textTheme.bodySmall,
                                          ),
                                        ),
                                      ],
                                    )
                                  : ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: LinearProgressIndicator(
                                        minHeight: 10,
                                        value: progressValue,
                                      ),
                                    ));

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              buttons,
                              if (showScanProgress) ...[
                                const SizedBox(height: 12),
                                progressBar,
                              ],
                            ],
                          );
                        },
                      ),

                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.surface.withOpacity(0.55),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: cs.outlineVariant.withOpacity(0.35)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('狀態：$_status', style: theme.textTheme.bodyMedium),
                            const SizedBox(height: 6),
                            Text('檔案：$_fileCount、PRS1檔案：$_prs1BlobCount、睡眠場次：${appState.prs1Sessions.length}',
                                style: theme.textTheme.bodySmall),
                            if (snap != null) ...[
                              const SizedBox(height: 6),
                              Text('資料夾：${snap.folderPath}', style: theme.textTheme.bodySmall),
                            ],
                            const SizedBox(height: 10),

                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      Expanded(
                        child: Builder(builder: (context) {
                          final bool showScanProgress = _scanTotal > 0;
                          final double? progressValue = showScanProgress ? (_scanDone / _scanTotal) : null;

                          // 「統計引擎運作用中.........」出現後，就把注意事項關閉。
                          final bool showComputingHint =
                              (appState.enginePhase == EnginePhase.computing) &&
                              (!showScanProgress || (progressValue != null && progressValue >= 1.0));

                          // 注意事項：資料載入前顯示；一旦 computing hint 出現就關閉。
                          final bool showNotice = appState.prs1Sessions.isEmpty && !showComputingHint;

                          if (showComputingHint) {
                            final msg = (appState.enginePhaseMessage.isNotEmpty)
                                ? appState.enginePhaseMessage
                                : '統計引擎運作中，請不要關閉本軟體';
                            return Center(
                              child: _SoftBlinkingHintText(
                                key: const ValueKey('engine_hint_blink_center'),
                                text: msg,
                              ),
                            );
                          }

                          if (!showNotice) return const SizedBox.shrink();

                          // 「主題色的深色」底：用 brandColor 往黑色加深，確保深/淺主題都清楚。
                          final Color bg = Color.lerp(appState.brandColor.color, Colors.black, 0.58)!;

                          const String noticeText = '''注意事項

免責聲明
01. 本應用程式絕非醫學專業指導的替代品。
02. 由於製造商對於文件格式釋出有限，本應用程式所顯示數據的準確性，無法以任何方式得到保證。
03. 所有生成的統計數據報告僅供個人陽壓呼吸睡眠治療成果的參考資料，並旨在盡可能保持準確。
04. 本應用程式的統計報告內容，是基於陽壓呼吸治療器所回報的數據。此類數據是否可用於合規性或其他目的，需由審核機構裁定。
05. 雖然本應用程式可以得到陽壓治療呼吸器的統計資料，但它不是官方醫療診斷工具。
06. 如果您對陽壓治療呼吸機的數據有疑慮，建議還是要諮詢您的呼吸治療師或是胸腔內科主治醫師。

版權宣告
01. 本應用程式基於 OSCAR 自由軟體（指自由度，而非僅指免費），依據 GNU 通用公共授權條款第三版 (GPL v3) 發佈。
02. 本應用程式基於 OSCAR 自由軟體開源精神，因此依據 GNU 通用公共授權條款第三版 (GPL v3) 發佈。
03. 本應用程式完整程式碼： https://github.com/8xespace/PRS1_CPAP
04. 本應用程式不提供任何保證，且不對其在任何特定用途下的適用性做出任何聲明。
05. 本應用程式在法律上聲明，不承擔任何軟體瑕疵或適用性的擔保責任。
''';

                          return Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: bg,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: Colors.white.withOpacity(0.12)),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: Scrollbar(
                                controller: _noticeScrollCtrl,
                                thumbVisibility: true,
                                child: SingleChildScrollView(
                                  controller: _noticeScrollCtrl,
                                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                                  child: Text(
                                    noticeText,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: Colors.white,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
],
                  ),
                ),
                  ),
                ),
              ),
            ),
            BottomControlsBar(appState: appState),
          ],
        ),
      ),
    );
  }





  /// Merge per-file partial PRS1 sessions into a single session keyed by session id.
  ///
  /// On Philips DreamStation SD cards, the same therapy session id (8-hex filename)
  /// appears across multiple extensions. If we don't merge, downstream daily
  /// aggregation can't see leak/pressure samples alongside usage.
  List<Prs1Session> _mergePrs1Sessions(List<Prs1Session> sessions) {
    String? keyOf(Prs1Session s) {
      final sp = s.sourcePath;
      if (sp == null || sp.isEmpty) return null;
      final m = RegExp(r'([0-9A-Fa-f]{8})\.(?:000|001|002|005)\b').firstMatch(sp);
      return m?.group(1)?.toLowerCase();
    }

    final Map<String, Prs1Session> byKey = <String, Prs1Session>{};
    final List<Prs1Session> passthrough = <Prs1Session>[];

    for (final s in sessions) {
      final k = keyOf(s);
      if (k == null) {
        passthrough.add(s);
        continue;
      }

      final prev = byKey[k];
      if (prev == null) {
        byKey[k] = s;
        continue;
      }

      // Merge fields conservatively: prefer non-empty / non-zero.
      final mergedStart = prev.start.isBefore(s.start) ? prev.start : s.start;
      final mergedEnd = prev.end.isAfter(s.end) ? prev.end : s.end;
      int? mergedMinutesUsed;
      if (prev.minutesUsed != null && s.minutesUsed != null) {
        mergedMinutesUsed = (prev.minutesUsed! >= s.minutesUsed!) ? prev.minutesUsed : s.minutesUsed;
      } else {
        mergedMinutesUsed = prev.minutesUsed ?? s.minutesUsed;
      }

      final mergedEvents = <Prs1Event>[...prev.events, ...s.events];
      final mergedPressureSamples = <Prs1SignalSample>[...prev.pressureSamples, ...s.pressureSamples];
      final mergedExhalePressureSamples = <Prs1SignalSample>[...prev.exhalePressureSamples, ...s.exhalePressureSamples];
      final mergedLeakSamples = <Prs1SignalSample>[...prev.leakSamples, ...s.leakSamples];
      final mergedFlowSamples = <Prs1SignalSample>[...prev.flowSamples, ...s.flowSamples];
      final mergedFlexSamples = <Prs1SignalSample>[...prev.flexSamples, ...s.flexSamples];

      // Keep the "best" sourcePath for debugging.
      final mergedSourcePath = (prev.sourcePath != null && prev.sourcePath!.length >= (s.sourcePath?.length ?? 0))
          ? prev.sourcePath
          : s.sourcePath;

      // IMPORTANT: Preserve high-rate waveforms (flowWaveform is required for breath-derived metrics).
      // Most sessions have waveform only from .005; other files contribute pressure/leak samples.
      Prs1WaveformChannel? mergedFlowWaveform;
      if (prev.flowWaveform == null) {
        mergedFlowWaveform = s.flowWaveform;
      } else if (s.flowWaveform == null) {
        mergedFlowWaveform = prev.flowWaveform;
      } else {
        // If both exist, keep the one with more samples (avoid double-counting overlaps).
        mergedFlowWaveform = (prev.flowWaveform!.samples.length >= s.flowWaveform!.samples.length)
            ? prev.flowWaveform
            : s.flowWaveform;
      }

      // Preserve derived breaths if already computed; otherwise keep empty and let aggregators compute later.
      final mergedBreaths = (prev.breaths.isNotEmpty)
          ? prev.breaths
          : (s.breaths.isNotEmpty ? s.breaths : const <Prs1Breath>[]);

      byKey[k] = Prs1Session(
        start: mergedStart,
        end: mergedEnd,
        events: mergedEvents,
        minutesUsed: mergedMinutesUsed,
        pressureSamples: mergedPressureSamples,
        exhalePressureSamples: mergedExhalePressureSamples,
        leakSamples: mergedLeakSamples,
        flowSamples: mergedFlowSamples,
        flexSamples: mergedFlexSamples,
        flowWaveform: mergedFlowWaveform,
        breaths: mergedBreaths,
        sourcePath: mergedSourcePath,
        sourceLabel: 'merged',
      );
    }

    return <Prs1Session>[...byKey.values, ...passthrough];
  }
}

class _SoftBlinkingHintText extends StatefulWidget {
  const _SoftBlinkingHintText({
    super.key,
    required this.text,
  });

  final String text;

  @override
  State<_SoftBlinkingHintText> createState() => _SoftBlinkingHintTextState();
}

class _SoftBlinkingHintTextState extends State<_SoftBlinkingHintText> {
  static const Duration _tick = Duration(milliseconds: 950);
  static const Duration _anim = Duration(milliseconds: 520);

  Timer? _timer;
  bool _on = true;

  @override
  void initState() {
    super.initState();
    // Timer-driven blinking: does not depend on TickerProvider and is resilient to frequent rebuilds.
    _timer = Timer.periodic(_tick, (_) {
      if (!mounted) return;
      setState(() => _on = !_on);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedOpacity(
      opacity: _on ? 1.0 : 0.18,
      duration: _anim,
      curve: Curves.easeInOut,
      child: Text(
        widget.text,
        textAlign: TextAlign.center,
        style: (theme.textTheme.titleMedium ?? theme.textTheme.titleSmall)?.copyWith(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: Colors.black,
        ),
      ),
    );
  }
}