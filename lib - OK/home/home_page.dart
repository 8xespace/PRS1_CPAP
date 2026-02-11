// lib/home/home_page.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../features/folder_access/folder_access_service.dart';
import '../features/folder_access/folder_access_state.dart';
import '../features/folder_access/platform/folder_access_ios.dart';
import '../features/prs1/decode/prs1_loader.dart';
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
  // Lightweight logger shims (some patches emit logW/logD from within HomePage).
  // Keeping them local avoids adding cross-module dependencies.
  void logW(String msg) {
    // ignore: avoid_print
    print('[W] $msg');
  }

  void logD(String msg) {
    // ignore: avoid_print
    print('[D] $msg');
  }

  final FolderAccessState _folderState = FolderAccessState();
  late final FolderAccessService _folderService;

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
    super.dispose();
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
      WebPickedFolderResult? picked;
      picked = await WebImport.pickFolderAndReadPrs1(
        isPrs1Candidate: _isPrs1Candidate,
        onProgress: (scanned, total, prs1Read) {
          if (!mounted) return;
          setState(() {
            _scanDone = scanned;
            _scanTotal = total;
            _status = '讀取中...（檔案 $total / PRS1檔案 $prs1Read）';
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
        _status = '已取得檔案清單（${pickedResult.allFiles.length}）... 開始解析（PRS1檔案: ${pickedResult.prs1BytesByRelPath.length}）...';
        _fileCount = pickedResult.allFiles.length;
        _prs1BlobCount = pickedResult.prs1BytesByRelPath.length;
      });

      final loader = Prs1Loader();
      final sessions = <Prs1Session>[];

      int _prs1ParseFailures = 0;
      for (final e in pickedResult.prs1BytesByRelPath.entries) {
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
        prs1BytesByRelPath: pickedResult.prs1BytesByRelPath,
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

      // 只把 PRS1 候選檔讀進記憶體（避免整張卡全部吃進來）
      for (final f in allFiles) {
        final pl = f.relativePath.toLowerCase();
        if (!_isPrs1Candidate(pl)) continue;
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
      appStateStore.setEnginePhase(EnginePhase.error, message: '發生錯誤：$e');
      setState(() {
        _busy = false;
        _status = '發生錯誤：$e';
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
      backgroundColor: cs.surfaceVariant.withOpacity(0.35),
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
                    color: cs.surfaceVariant.withOpacity(0.45),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: cs.outlineVariant.withOpacity(0.35),
                      width: 1,
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [Text(
                        kIsWeb
                            ? 'Web 推薦做法：點「讀取記憶卡」→ 選一個 zip（整張 SD 卡或其子資料夾）。\n'
                                '完成後：App 會立刻取得檔案清單＋相對路徑，並把 PRS1 相關檔案讀成 bytes 後開始解析。'
                            : '推薦做法：點「讀取記憶卡」→ 選 USB/SD 卡根目錄（或其上層資料夾）。\n'
                                '完成後：App 會立刻取得檔案清單＋相對路徑，並把 PRS1 相關檔案讀成 bytes 後開始解析。',
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

                          final buttons = isWide
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
                                );

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
                          final bool showComputingHint =
                              (appState.enginePhase == EnginePhase.computing) &&
                              (!showScanProgress || (progressValue != null && progressValue >= 1.0));
                          if (!showComputingHint) return const SizedBox.shrink();
                          final msg = (appState.enginePhaseMessage.isNotEmpty)
                              ? appState.enginePhaseMessage
                              : '統計引擎運作中，請不要關閉本軟體';
                          return Center(
                            child: _SoftBlinkingHintText(
                              key: const ValueKey('engine_hint_blink_center'),
                              text: msg,
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