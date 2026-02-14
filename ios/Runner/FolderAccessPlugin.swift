// ios/Runner/FolderAccessPlugin.swift
//
// MethodChannel: "cpap.folder_access"
//
// Purpose:
// - iOS folder pick returns a security-scoped URL that Flutter (dart:io) cannot
//   reliably enumerate directly unless the resource is actively "started".
// - To make scanning stable, we COPY the selected folder into the app sandbox
//   (Application Support/ImportedPRS1/<uuid>/...) and return that sandbox path
//   to Flutter. Flutter then uses dart:io to recursively list/read files.
//
// You MUST also wire this plugin from AppDelegate.swift (see README_IOS_FOLDER_ACCESS.md).

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
      result(["granted": false, "path": NSNull(), "bookmark": NSNull()])
      return
    }
    guard let presenter = presenter else {
      result(["granted": false, "path": NSNull(), "bookmark": NSNull()])
      return
    }

    pendingResult = result

    let types: [UTType] = [.folder]
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
    picker.allowsMultipleSelection = false
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  private func restoreBookmark(_ result: @escaping FlutterResult) {
    // If we already have a copied sandbox path, prefer it (fast + no prompt).
    if let p = ud.string(forKey: kCopiedPath), FileManager.default.fileExists(atPath: p) {
      result(["granted": true, "path": p])
      return
    }

    guard let b64 = ud.string(forKey: kBookmark),
          let data = Data(base64Encoded: b64) else {
      result(["granted": false, "path": NSNull()])
      return
    }

    do {
      var stale = false
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )

      // Recopy into sandbox on restore (keeps Flutter access stable).
      let copied = try withSecurityScoped(url: url) { srcUrl in
        return try copyFolderToSandbox(srcUrl)
      }

      ud.set(copied, forKey: kCopiedPath)
      result(["granted": true, "path": copied])
    } catch {
      result(["granted": false, "path": NSNull()])
    }
  }

  // MARK: - UIDocumentPickerDelegate

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    if let r = pendingResult {
      pendingResult = nil
      r(["granted": false, "path": NSNull(), "bookmark": NSNull()])
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let r = pendingResult else { return }
    pendingResult = nil

    guard let url = urls.first else {
      r(["granted": false, "path": NSNull(), "bookmark": NSNull()])
      return
    }

    do {
      // Create / persist bookmark (so next launch can restore without prompting).
      let bookmarkData = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
      let b64 = bookmarkData.base64EncodedString()
      ud.set(b64, forKey: kBookmark)

      // Copy the whole folder into sandbox.
      let copied = try withSecurityScoped(url: url) { srcUrl in
        return try copyFolderToSandbox(srcUrl)
      }
      ud.set(copied, forKey: kCopiedPath)

      r(["granted": true, "path": copied, "bookmark": b64])
    } catch {
      r(["granted": false, "path": NSNull(), "bookmark": NSNull()])
    }
  }

  // MARK: - Helpers

  private func withSecurityScoped<T>(url: URL, _ body: (URL) throws -> T) throws -> T {
    let ok = url.startAccessingSecurityScopedResource()
    defer {
      if ok { url.stopAccessingSecurityScopedResource() }
    }
    return try body(url)
  }

  private func copyFolderToSandbox(_ srcUrl: URL) throws -> String {
    let fm = FileManager.default
    let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let root = support.appendingPathComponent("ImportedPRS1", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    let dest = root.appendingPathComponent(UUID().uuidString, isDirectory: true)

    // If somehow exists, remove.
    if fm.fileExists(atPath: dest.path) {
      try fm.removeItem(at: dest)
    }

    try fm.copyItem(at: srcUrl, to: dest)
    return dest.path
  }
}
