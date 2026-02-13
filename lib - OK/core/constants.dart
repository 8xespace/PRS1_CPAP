// lib/core/constants.dart

class AppConstants {
  static const String appName = '頂極制作所';

  /// Storage folder name (in app documents directory) for imported CPAP data.
  static const String dataRootFolder = 'cpap_data';

  /// Date formatting (UI) uses Asia/Taipei by default.
  static const String defaultTimeZone = 'Asia/Taipei';

  /// PRS1 flow waveform gain calibration.
  ///
  /// DreamStation flow waveform in this project tends to run ~6–7% high vs OSCAR.
  /// Apply a global gain to align Tidal Volume (TV), Minute Ventilation (MV) and derived stats.
  /// Tuned to match OSCAR Stats (Med/P95) on the provided sample data.
  static const double prs1FlowGain = 0.9375;
}
