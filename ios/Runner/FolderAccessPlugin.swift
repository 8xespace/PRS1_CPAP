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

  // ---------------- 35-day gate copy (iOS) ----------------
  //
  // Goal:
  // - Do NOT copy the entire SD folder into sandbox.
  // - Enumerate source folder, determine a "newest" reference timestamp, then only copy files
  //   that fall within [newest-35days, newest].
  //
  // Timestamp sources (best effort):
  // 1) HeaderProbe (more accurate for PRS1):
  //    - chunk (.000..999): common header unix seconds at bytes[11..14] (u32le)
  //    - EDF: header startdate/starttime at offsets 168..183
  // 2) Fallback: file modificationDate
  //
  // NOTE: Unknown timestamps are treated as ALLOWED (conservative), but they still must be PRS1 candidates.

  private struct _SrcEntry {
    let url: URL
    let relPath: String
    let ts: Date?
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
    try fm.createDirectory(at: dest, withIntermediateDirectories: true, attributes: nil)

    // Pass 1: enumerate candidate files & compute newest timestamp.
    let entries = try enumeratePrs1Candidates(srcUrl: srcUrl)

    var newest: Date? = nil
    for e in entries {
      if let t = e.ts {
        if newest == nil || t > newest! { newest = t }
      }
    }
    let newestOrNow = newest ?? Date()
    let gateDays: TimeInterval = 35 * 24 * 60 * 60
    let cutoff = newestOrNow.addingTimeInterval(-gateDays)

    // Pass 2: copy allowed files.
    var copiedCount = 0
    for e in entries {
      let ok: Bool
      if let t = e.ts {
        ok = (t >= cutoff) && (t <= newestOrNow)
      } else {
        // conservative: unknown timestamp treated as allowed
        ok = true
      }
      if !ok { continue }

      let destFile = dest.appendingPathComponent(e.relPath, isDirectory: false)
      let parent = destFile.deletingLastPathComponent()
      try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)

      if fm.fileExists(atPath: destFile.path) {
        try? fm.removeItem(at: destFile)
      }
      try fm.copyItem(at: e.url, to: destFile)
      copiedCount += 1
    }

    // Persist a tiny debug print; safe even in release.
    // (Flutter side can still choose to add its own debug logs.)
    // ignore: avoid_print
    print("[CPAP][iOS] Folder copy gate: newest=\(newestOrNow) cutoff=\(cutoff) copied=\(copiedCount)/\(entries.count)")

    return dest.path
  }

  private func enumeratePrs1Candidates(srcUrl: URL) throws -> [_SrcEntry] {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [
      .isRegularFileKey,
      .contentModificationDateKey,
      .fileSizeKey,
    ]
    guard let en = fm.enumerator(at: srcUrl, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
      return []
    }

    var out: [_SrcEntry] = []
    while let obj = en.nextObject() as? URL {
      let rv = try obj.resourceValues(forKeys: Set(keys))
      if rv.isRegularFile != true { continue }

      let rel = obj.path.replacingOccurrences(of: srcUrl.path, with: "")
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      if rel.isEmpty { continue }

      let lower = rel.lowercased()
      if !isPrs1Candidate(lower) { continue }

      let ts = probePrs1Timestamp(fileUrl: obj, lowerRelPath: lower) ?? rv.contentModificationDate
      out.append(_SrcEntry(url: obj, relPath: rel, ts: ts))
    }

    // stable ordering (not required, but helps when debugging)
    out.sort { $0.relPath < $1.relPath }
    return out
  }

  private func isPrs1Candidate(_ lowerRelPath: String) -> Bool {
    if lowerRelPath.hasSuffix(".edf") || lowerRelPath.hasSuffix(".tgt") || lowerRelPath.hasSuffix(".dat") {
      return true
    }
    // numeric 3-digit extension: .000 .. .999
    if lowerRelPath.count >= 4 {
      let ext = String(lowerRelPath.suffix(4)) // ".123"
      if ext.first == "." {
        let d = ext.dropFirst()
        if d.count == 3 && d.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
          return true
        }
      }
    }
    return false
  }

  private func probePrs1Timestamp(fileUrl: URL, lowerRelPath: String) -> Date? {
    do {
      if lowerRelPath.hasSuffix(".edf") {
        // EDF header requires 184 bytes for startdate/starttime.
        let head = try readHead(fileUrl: fileUrl, maxBytes: 184)
        return parseEdfStartDate(head: head)
      }

      // PRS1 chunk: needs 15 bytes.
      if lowerRelPath.count >= 4 {
        let ext = String(lowerRelPath.suffix(4))
        if ext.first == "." {
          let d = ext.dropFirst()
          if d.count == 3 && d.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
            let head = try readHead(fileUrl: fileUrl, maxBytes: 15)
            if head.count >= 15 {
              let ts = u32le(head, 11)
              // safety: 2000..2100 unix seconds
              if ts >= 946684800 && ts <= 4102444800 {
                return Date(timeIntervalSince1970: TimeInterval(ts))
              }
            }
          }
        }
      }
    } catch {
      // swallow errors; fallback to modificationDate
    }
    return nil
  }

  private func readHead(fileUrl: URL, maxBytes: Int) throws -> Data {
    let h = try FileHandle(forReadingFrom: fileUrl)
    defer { try? h.close() }
    if #available(iOS 13.0, *) {
      return try h.read(upToCount: maxBytes) ?? Data()
    } else {
      return h.readData(ofLength: maxBytes)
    }
  }

  private func u32le(_ data: Data, _ offset: Int) -> UInt32 {
    if data.count < offset + 4 { return 0 }
    let b0 = UInt32(data[offset])
    let b1 = UInt32(data[offset + 1]) << 8
    let b2 = UInt32(data[offset + 2]) << 16
    let b3 = UInt32(data[offset + 3]) << 24
    return b0 | b1 | b2 | b3
  }

  private func parseEdfStartDate(head: Data) -> Date? {
    if head.count < 184 { return nil }

    func readAscii(_ start: Int, _ len: Int) -> String {
      let sub = head.subdata(in: start..<(start + len))
      return String(data: sub, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    let date = readAscii(168, 8) // dd.mm.yy
    let time = readAscii(176, 8) // hh.mm.ss

    let d = date.split(separator: ".")
    let t = time.split(separator: ".")
    if d.count != 3 || t.count != 3 { return nil }

    guard
      let dd = Int(d[0]),
      let mm = Int(d[1]),
      let yy2 = Int(d[2]),
      let hh = Int(t[0]),
      let mi = Int(t[1]),
      let ss = Int(t[2])
    else { return nil }

    // EDF 2-digit year heuristic (same as Dart side):
    // - 85..99 => 1985..1999
    // - else => 2000..2084
    let year = (yy2 >= 85) ? (1900 + yy2) : (2000 + yy2)

    var comps = DateComponents()
    comps.calendar = Calendar.current
    comps.timeZone = TimeZone.current
    comps.year = year
    comps.month = mm
    comps.day = dd
    comps.hour = hh
    comps.minute = mi
    comps.second = ss
    return comps.date
  }
}

