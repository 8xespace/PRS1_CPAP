import UIKit
import Flutter
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, UIDocumentPickerDelegate {

  private var pendingResult: FlutterResult?
  private let bookmarkKey = "cpap_folder_bookmark_v1"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    let controller: FlutterViewController = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: "cpap.folder_access", binaryMessenger: controller.binaryMessenger)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "pickFolder":
        self.presentFolderPicker(result: result)
      case "restoreBookmark":
        self.restoreBookmark(result: result)
      case "clearBookmark":
        self.clearBookmark(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - Picker

  private func presentFolderPicker(result: @escaping FlutterResult) {
    if pendingResult != nil {
      result(FlutterError(code: "BUSY", message: "Another folder picker request is in progress.", details: nil))
      return
    }
    pendingResult = result

    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    picker.modalPresentationStyle = .formSheet

    window?.rootViewController?.present(picker, animated: true, completion: nil)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingResult?(FlutterError(code: "CANCELLED", message: "User cancelled folder selection.", details: nil))
    pendingResult = nil
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else {
      pendingResult?(FlutterError(code: "NO_URL", message: "No folder URL returned.", details: nil))
      pendingResult = nil
      return
    }

    let ok = url.startAccessingSecurityScopedResource()
    defer { if ok { url.stopAccessingSecurityScopedResource() } }

    do {
      let data = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
      UserDefaults.standard.set(data, forKey: bookmarkKey)
    } catch {
      // Ignore persisting failures; selection still works for this session.
    }

    pendingResult?(url.path)
    pendingResult = nil
  }

  // MARK: - Bookmark restore

  private func restoreBookmark(result: @escaping FlutterResult) {
    guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
      result(FlutterError(code: "NO_BOOKMARK", message: "No saved folder authorization.", details: nil))
      return
    }

    var isStale = false
    do {
      let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)

      let ok = url.startAccessingSecurityScopedResource()
      defer { if ok { url.stopAccessingSecurityScopedResource() } }

      if isStale {
        do {
          let newData = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
          UserDefaults.standard.set(newData, forKey: bookmarkKey)
        } catch { /* ignore */ }
      }

      result(url.path)
    } catch {
      result(FlutterError(code: "BOOKMARK_FAIL", message: "Failed to resolve saved authorization.", details: String(describing: error)))
    }
  }

  private func clearBookmark(result: @escaping FlutterResult) {
    UserDefaults.standard.removeObject(forKey: bookmarkKey)
    result(true)
  }
}
