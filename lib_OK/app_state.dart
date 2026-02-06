// lib/app_state.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'features/prs1/model/prs1_session.dart';
import 'features/prs1/aggregate/prs1_daily_models.dart';
import 'features/prs1/aggregate/prs1_trend_models.dart';
import 'features/prs1/waveform/prs1_waveform_index.dart';



///------------------------------------------------------------
/// CPAP SD 卡匯入（資料夾模式）資料模型
///------------------------------------------------------------

class CpapImportedFile {
  final String absolutePath;
  final String relativePath;
  final int sizeBytes;

  const CpapImportedFile({
    required this.absolutePath,
    required this.relativePath,
    required this.sizeBytes,
  });
}

class CpapImportSnapshot {
  final String folderPath;
  final List<CpapImportedFile> allFiles;

  /// Only PRS1-relevant blobs are loaded into memory (keyed by relative path).
  final Map<String, Uint8List> prs1BytesByRelPath;

  const CpapImportSnapshot({
    required this.folderPath,
    required this.allFiles,
    required this.prs1BytesByRelPath,
  });
}

///------------------------------------------------------------
/// ① 品牌色 BrandColor
///------------------------------------------------------------

enum BrandColor {
  pink,
  orange,
  green,
  blue,
}

/// 給 BrandColor 取得主色 Color
extension BrandColorX on BrandColor {
  Color get color {
    switch (this) {
      case BrandColor.pink:
        return const Color(0xFFF8A3C4); // 主視覺粉
      case BrandColor.orange:
        return const Color(0xFFFFC894); // 柔橘
      case BrandColor.green:
        return const Color(0xFFA1E5B2); // 清綠
      case BrandColor.blue:
        return const Color(0xFF93B7FF); // 淺藍
    }
  }

  String get label {
    switch (this) {
      case BrandColor.pink:
        return '粉';
      case BrandColor.orange:
        return '橘';
      case BrandColor.green:
        return '綠';
      case BrandColor.blue:
        return '藍';
    }
  }
}

///------------------------------------------------------------
/// ②（可延伸）資料：我的最愛 / 瀏覽紀錄 / 下次想去
///------------------------------------------------------------

class FavoriteEntry {
  final String key;
  final String title;
  final String note;
  final DateTime createdAt;

  const FavoriteEntry({
    required this.key,
    required this.title,
    required this.note,
    required this.createdAt,
  });

  FavoriteEntry copyWith({String? title, String? note}) {
    return FavoriteEntry(
      key: key,
      title: title ?? this.title,
      note: note ?? this.note,
      createdAt: createdAt,
    );
  }

  factory FavoriteEntry.fromJson(Map<String, dynamic> json) {
    return FavoriteEntry(
      key: json['key'] as String,
      title: json['title'] as String? ?? '',
      note: json['note'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'title': title,
        'note': note,
        'createdAt': createdAt.toIso8601String(),
      };
}

class BrowseRecord {
  final String key;
  final String title;
  final String note;
  final DateTime visitedAt;

  const BrowseRecord({
    required this.key,
    required this.title,
    required this.note,
    required this.visitedAt,
  });

  factory BrowseRecord.fromJson(Map<String, dynamic> json) {
    return BrowseRecord(
      key: json['key'] as String,
      title: json['title'] as String? ?? '',
      note: json['note'] as String? ?? '',
      visitedAt: DateTime.tryParse(json['visitedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'title': title,
        'note': note,
        'visitedAt': visitedAt.toIso8601String(),
      };
}

class NextWantEntry {
  final String key;
  final String title;
  final String note;
  final DateTime createdAt;

  const NextWantEntry({
    required this.key,
    required this.title,
    required this.note,
    required this.createdAt,
  });

  NextWantEntry copyWith({String? title, String? note}) {
    return NextWantEntry(
      key: key,
      title: title ?? this.title,
      note: note ?? this.note,
      createdAt: createdAt,
    );
  }

  factory NextWantEntry.fromJson(Map<String, dynamic> json) {
    return NextWantEntry(
      key: json['key'] as String,
      title: json['title'] as String? ?? '',
      note: json['note'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'title': title,
        'note': note,
        'createdAt': createdAt.toIso8601String(),
      };
}

///------------------------------------------------------------
/// AppState：全域狀態（母本核心）
/// - ThemeMode（明暗）
/// - BrandColor（四顆主題色）
/// - Favorites / History / NextWants（預留：後續模組可直接沿用）
///------------------------------------------------------------

class AppState extends ChangeNotifier {
  AppState() {
    _loadPrefs();
  }

  // Convenience accessor for legacy pages: AppState.of(context).
  // The state is provided by AppStateScope (InheritedNotifier).
  static AppState of(BuildContext context) => AppStateScope.of(context);

  /// 強制預設為 Light（避免預設變成黑色主題）
  ThemeMode _themeMode = ThemeMode.light;
  BrandColor _brandColor = BrandColor.pink;

  
  // ------------------------------------------------------------
  // PRS1 parsed sessions (in-memory for now)
  // ------------------------------------------------------------
  List<Prs1Session> _prs1Sessions = const [];
  List<Prs1Session> get prs1Sessions => _prs1Sessions;

  void setPrs1Sessions(List<Prs1Session> sessions) {
    _prs1Sessions = List.unmodifiable(sessions);
    notifyListeners();
  }

  void clearPrs1Sessions() {
    _prs1Sessions = const [];
    notifyListeners();
  }




// ------------------------------------------------------------
// Milestone G: Waveform index (viewport-ready; UI-agnostic)
// ------------------------------------------------------------
Prs1WaveformIndex? _prs1WaveformIndex;
Prs1WaveformIndex? get prs1WaveformIndex => _prs1WaveformIndex;

void setPrs1WaveformIndex(Prs1WaveformIndex? index) {
  _prs1WaveformIndex = index;
  notifyListeners();
}

void clearPrs1WaveformIndex() {
  _prs1WaveformIndex = null;
  notifyListeners();
}

// ------------------------------------------------------------
// Layer 6: Daily Aggregation (engine output)
// ------------------------------------------------------------
List<Prs1DailyBucket> _prs1DailyBuckets = const [];
List<Prs1DailyBucket> get prs1DailyBuckets => _prs1DailyBuckets;

void setPrs1DailyBuckets(List<Prs1DailyBucket> buckets) {
  _prs1DailyBuckets = List.unmodifiable(buckets);
  notifyListeners();
}

void clearPrs1DailyBuckets() {
  _prs1DailyBuckets = const [];
  notifyListeners();
}



// ------------------------------------------------------------
// Layer 7: Weekly / Monthly trend buckets (engine output)
// ------------------------------------------------------------
List<Prs1WeeklyBucket> _prs1WeeklyBuckets = const [];
List<Prs1WeeklyBucket> get prs1WeeklyBuckets => _prs1WeeklyBuckets;

void setPrs1WeeklyBuckets(List<Prs1WeeklyBucket> buckets) {
  _prs1WeeklyBuckets = List.unmodifiable(buckets);
  notifyListeners();
}

void clearPrs1WeeklyBuckets() {
  _prs1WeeklyBuckets = const [];
  notifyListeners();
}

List<Prs1MonthlyBucket> _prs1MonthlyBuckets = const [];
List<Prs1MonthlyBucket> get prs1MonthlyBuckets => _prs1MonthlyBuckets;

void setPrs1MonthlyBuckets(List<Prs1MonthlyBucket> buckets) {
  _prs1MonthlyBuckets = List.unmodifiable(buckets);
  notifyListeners();
}

void clearPrs1MonthlyBuckets() {
  _prs1MonthlyBuckets = const [];
  notifyListeners();
}

// ------------------------------------------------------------
// CPAP import snapshot (folder mode)
// ------------------------------------------------------------
CpapImportSnapshot? _importSnapshot;
CpapImportSnapshot? get importSnapshot => _importSnapshot;

void setImportSnapshot(CpapImportSnapshot snapshot) {
  _importSnapshot = snapshot;
  notifyListeners();
}

void clearImportSnapshot() {
  _importSnapshot = null;
  notifyListeners();
}

ThemeMode get themeMode => _themeMode;
  BrandColor get brandColor => _brandColor;

  void setThemeMode(ThemeMode mode) {
    if (_themeMode == mode) return;
    _themeMode = mode;
    _saveThemeToPrefs();
    notifyListeners();
  }

  /// 給 BottomControlsBar 切換明暗用
  void toggleThemeMode() {
    _themeMode =
        _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    _saveThemeToPrefs();
    notifyListeners();
  }

  void setBrandColor(BrandColor color) {
    if (_brandColor == color) return;
    _brandColor = color;
    _saveBrandColorToPrefs();
    notifyListeners();
  }

  ///--------------------------------------------------------
  /// Favorites
  ///--------------------------------------------------------

  final List<FavoriteEntry> _favorites = [];

  List<FavoriteEntry> get favorites => List.unmodifiable(_favorites);
  bool get hasFavorites => _favorites.isNotEmpty;

  Future<void> upsertFavorite({
    required String key,
    required String title,
    String note = '',
  }) async {
    final idx = _favorites.indexWhere((e) => e.key == key);
    if (idx >= 0) {
      _favorites[idx] = _favorites[idx].copyWith(title: title, note: note);
    } else {
      _favorites.add(
        FavoriteEntry(
          key: key,
          title: title,
          note: note,
          createdAt: DateTime.now(),
        ),
      );
    }
    await _saveFavoritesToPrefs();
    notifyListeners();
  }

  Future<void> removeFavorite(String key) async {
    _favorites.removeWhere((e) => e.key == key);
    await _saveFavoritesToPrefs();
    notifyListeners();
  }

  ///--------------------------------------------------------
  /// History
  ///--------------------------------------------------------

  final List<BrowseRecord> _history = [];

  List<BrowseRecord> get history => List.unmodifiable(_history);

  void addBrowseRecord({
    required String key,
    required String title,
    String note = '',
  }) {
    _history.removeWhere((e) => e.key == key);
    _history.insert(
      0,
      BrowseRecord(
        key: key,
        title: title,
        note: note,
        visitedAt: DateTime.now(),
      ),
    );
    _saveHistoryToPrefs();
    notifyListeners();
  }

  Future<void> clearHistory() async {
    _history.clear();
    await _saveHistoryToPrefs();
    notifyListeners();
  }

  ///--------------------------------------------------------
  /// NextWants
  ///--------------------------------------------------------

  final List<NextWantEntry> _nextWants = [];

  List<NextWantEntry> get nextWants => List.unmodifiable(_nextWants);

  Future<void> upsertNextWant({
    required String key,
    required String title,
    String note = '',
  }) async {
    final idx = _nextWants.indexWhere((e) => e.key == key);
    if (idx >= 0) {
      _nextWants[idx] = _nextWants[idx].copyWith(title: title, note: note);
    } else {
      _nextWants.add(
        NextWantEntry(
          key: key,
          title: title,
          note: note,
          createdAt: DateTime.now(),
        ),
      );
    }
    await _saveNextWantsToPrefs();
    notifyListeners();
  }

///--------------------------------------------------------
/// 偏好設定（母本：無外部套件版本）
///--------------------------------------------------------
///
/// 你目前的專案尚未在 pubspec.yaml 加入 `shared_preferences`，
/// 因此此母本先以「不落地儲存」方式提供可編譯、可運作的狀態管理。
///
/// 若你之後希望「記住」明暗模式 / 品牌色 / 清單資料，
/// 只需要：
/// 1) pubspec.yaml 加入 shared_preferences
/// 2) 以 SharedPreferences 版本替換本段（我也可直接幫你切回持久化版本）
///
/// 目前行為：
/// - 變更仍會立即生效（notifyListeners）
/// - 重新啟動後會回到預設值（light + pink）
///
static const _kPrefKeyThemeMode = 'themeMode';
static const _kPrefKeyBrandColor = 'brandColor';
static const _kPrefKeyFavorites = 'favorites';
static const _kPrefKeyHistory = 'history';
static const _kPrefKeyNextWants = 'nextWants';

Future<void> _loadPrefs() async {
  // No-op: template keeps everything in memory.
  notifyListeners();
}

Future<void> _saveThemeToPrefs() async {
  // No-op
}

Future<void> _saveBrandColorToPrefs() async => _saveThemeToPrefs();

Future<void> _saveFavoritesToPrefs() async {
  // No-op
}

Future<void> _saveHistoryToPrefs() async {
  // No-op
}

Future<void> _saveNextWantsToPrefs() async {
  // No-op
}
}

///------------------------------------------------------------
/// AppStateScope：全域 InheritedNotifier（讓任何頁面都可取用 AppState）
///------------------------------------------------------------

class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({
    super.key,
    required AppState notifier,
    required Widget child,
  }) : super(notifier: notifier, child: child);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'AppStateScope not found. Wrap your app with AppStateScope.');
    return scope!.notifier!;
  }
}


// Global singleton used to avoid context lookup issues in early scaffolding.
final AppState appStateStore = AppState();
