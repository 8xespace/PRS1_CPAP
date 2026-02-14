import UIKit
import Flutter
import UniformTypeIdentifiers

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate, UIDocumentPickerDelegate {
  private var pendingResult: FlutterResult?
  private let bookmarkKey = "cpap_folder_bookmark_b64"
  private var securityScopedURL: URL?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller: FlutterViewController = window?.rootViewController as! FlutterViewController

    let channel = FlutterMethodChannel(name: "cpap.folder_access", binaryMessenger: controller.binaryMessenger)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "restoreBookmark":
        self.handleRestoreBookmark(result: result)
      case "pickFolder":
        self.handlePickFolder(result: result)
      case "persistBookmark":
        if let args = call.arguments as? [String: Any],
           let b64 = args["bookmark"] as? String {
          UserDefaults.standard.set(b64, forKey: self.bookmarkKey)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func handleRestoreBookmark(result: @escaping FlutterResult) {
    guard let b64 = UserDefaults.standard.string(forKey: bookmarkKey),
          let data = Data(base64Encoded: b64) else {
      result(["granted": false, "path": NSNull()])
      return
    }

    var stale = false
    do {
      let url = try URL(resolvingBookmarkData: data,
                        options: [.withSecurityScope],
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale)

      if stale {
        // If stale, we still try to access; user may need to re-pick.
      }

      if url.startAccessingSecurityScopedResource() {
        self.securityScopedURL?.stopAccessingSecurityScopedResource()
        self.securityScopedURL = url
        result(["granted": true, "path": url.path])
      } else {
        result(["granted": false, "path": NSNull()])
      }
    } catch {
      result(["granted": false, "path": NSNull()])
    }
  }

  private func handlePickFolder(result: @escaping FlutterResult) {
    // Avoid concurrent pickers.
    if pendingResult != nil {
      result(["granted": false, "path": NSNull()])
      return
    }
    pendingResult = result

    DispatchQueue.main.async {
      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
      } else {
        // iOS 13 fallback: best-effort (folder picking is limited). Use public.data to allow picking a file, then user can choose a folder-like provider.
        picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
      }
      picker.delegate = self
      picker.allowsMultipleSelection = false

      if let root = self.window?.rootViewController {
        root.present(picker, animated: true, completion: nil)
      } else {
        self.finishPick(granted: false, url: nil, bookmarkB64: nil)
      }
    }
  }

  // MARK: - UIDocumentPickerDelegate

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finishPick(granted: false, url: nil, bookmarkB64: nil)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else {
      finishPick(granted: false, url: nil, bookmarkB64: nil)
      return
    }

    // Start security-scoped access and create a bookmark for persistence.
    let granted = url.startAccessingSecurityScopedResource()
    if granted {
      self.securityScopedURL?.stopAccessingSecurityScopedResource()
      self.securityScopedURL = url
    }

    var b64: String? = nil
    if granted {
      do {
        let data = try url.bookmarkData(options: [.withSecurityScope],
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        b64 = data.base64EncodedString()
        UserDefaults.standard.set(b64, forKey: bookmarkKey)
      } catch {
        // If bookmark fails, we still return path; user may need to pick again next time.
      }
    }

    finishPick(granted: granted, url: url, bookmarkB64: b64)
  }

  private func finishPick(granted: Bool, url: URL?, bookmarkB64: String?) {
    let res = pendingResult
    pendingResult = nil

    let pathVal: Any = url?.path ?? NSNull()
    let bVal: Any = bookmarkB64 ?? NSNull()

    res?(["granted": granted, "path": pathVal, "bookmark": bVal])
  }
}
