import Foundation
import Flutter
import UIKit
import UniformTypeIdentifiers

final class FolderAccessPlugin: NSObject, UIDocumentPickerDelegate {
  private let channel: FlutterMethodChannel
  private weak var presenter: UIViewController?
  private var pendingResult: FlutterResult?

  private let ud = UserDefaults.standard
  private let kBookmark = "cpap_folder_bookmark_b64"
  private let kCopiedPath = "cpap_folder_copied_path"

  init(channel: FlutterMethodChannel, presenter: UIViewController) {
    self.channel = channel
    self.presenter = presenter
    super.init()
    channel.setMethodCallHandler(self.onCall)
  }

  private func onCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickFolder":
      pickFolder(result)
    case "restoreBookmark":
      restoreBookmark(result)
    case "clearBookmark":
      clearBookmark(result)
    case "persistBookmark":
      if let args = call.arguments as? [String: Any],
         let b64 = args["bookmark"] as? String,
         !b64.isEmpty {
        ud.set(b64, forKey: kBookmark)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func pickFolder(_ result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(["granted": false, "path": NSNull(), "bookmark": NSNull(), "error": "BUSY"])
      return
    }
    guard let presenter = presenter else {
      result(["granted": false, "path": NSNull(), "bookmark": NSNull(), "error": "NO_PRESENTER"])
      return
    }

    pendingResult = result

    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
    picker.allowsMultipleSelection = false
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  private func restoreBookmark(_ result: @escaping FlutterResult) {
    if let p = ud.string(forKey: kCopiedPath), FileManager.default.fileExists(atPath: p) {
      result(["granted": true, "path": p, "error": NSNull()])
      return
    }

    guard let b64 = ud.string(forKey: kBookmark),
          let data = Data(base64Encoded: b64) else {
      result(["granted": false, "path": NSNull(), "error": "NO_BOOKMARK"])
      return
    }

    do {
      var stale = false
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withoutUI, .withoutMounting],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )

      let copied = try withSecurityScoped(url: url) { src in
        try copyFolderToSandbox(src)
      }
      ud.set(copied, forKey: kCopiedPath)

      if stale {
        do {
          let newData = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
          ud.set(newData.base64EncodedString(), forKey: kBookmark)
        } catch { }
      }

      result(["granted": true, "path": copied, "error": NSNull()])
    } catch {
      result(["granted": false, "path": NSNull(), "error": "BOOKMARK_FAIL: \(error)"])
    }
  }

  private func clearBookmark(_ result: @escaping FlutterResult) {
    ud.removeObject(forKey: kBookmark)
    ud.removeObject(forKey: kCopiedPath)
    result(true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    if let r = pendingResult {
      pendingResult = nil
      r(["granted": false, "path": NSNull(), "bookmark": NSNull(), "error": "CANCELLED"])
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let r = pendingResult else { return }
    pendingResult = nil

    guard let url = urls.first else {
      r(["granted": false, "path": NSNull(), "bookmark": NSNull(), "error": "NO_URL"])
      return
    }

    do {
      let bookmarkData = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
      let b64 = bookmarkData.base64EncodedString()
      ud.set(b64, forKey: kBookmark)

      let copied = try withSecurityScoped(url: url) { src in
        try copyFolderToSandbox(src)
      }
      ud.set(copied, forKey: kCopiedPath)

      r(["granted": true, "path": copied, "bookmark": b64, "error": NSNull()])
    } catch {
      r(["granted": false, "path": NSNull(), "bookmark": NSNull(), "error": "PICK_FAIL: \(error)"])
    }
  }

  private func withSecurityScoped<T>(url: URL, _ body: (URL) throws -> T) throws -> T {
    let ok = url.startAccessingSecurityScopedResource()
    defer { if ok { url.stopAccessingSecurityScopedResource() } }
    return try body(url)
  }

  private func copyFolderToSandbox(_ srcUrl: URL) throws -> String {
    let fm = FileManager.default
    let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let root = support.appendingPathComponent("ImportedPRS1", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)

    let dest = root.appendingPathComponent(UUID().uuidString, isDirectory: true)

    if fm.fileExists(atPath: dest.path) {
      try fm.removeItem(at: dest)
    }

    try fm.copyItem(at: srcUrl, to: dest)
    return dest.path
  }
}
