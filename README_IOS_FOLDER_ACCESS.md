# iOS 讀取整個資料夾（P-SERIES / SD 卡）- 必要設定

你目前在 iOS 上可以「選到資料夾」，但 Flutter 端無法像 Web/Chrome 一樣用 dart:io 直接遞迴掃描資料夾。
原因是：iOS 的「外部資料夾」屬於 **security-scoped resource**，必須在 native 端取得授權並在授權期間讀取，
最穩定的做法是：**把選到的資料夾整包複製進 App sandbox**，再交給 Flutter 掃描。

本修正版採用：
- MethodChannel: `cpap.folder_access`
- iOS 端：選取資料夾後 -> 建立 bookmark -> **複製到 Application Support/ImportedPRS1/<uuid>/** -> 回傳 sandbox path 給 Flutter
- Flutter 端：收到 sandbox path 後，`LocalFs.listFilesRecursive()` 就能正常掃描、讀取

---

## 1) 將 Swift 檔加入 Xcode

把這個檔案加入到專案：
- `ios/Runner/FolderAccessPlugin.swift`

（本 zip 已含此檔案）

---

## 2) 在 `ios/Runner/AppDelegate.swift` 接上 MethodChannel

在 `application(_:didFinishLaunchingWithOptions:)` 內加入：

```swift
import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: "cpap.folder_access", binaryMessenger: controller.binaryMessenger)
    _ = FolderAccessPlugin(channel: channel, presenter: controller)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
```

> 注意：如果你的 AppDelegate 已經有其它 channel / 設定，把上面這段「建立 channel + 初始化 FolderAccessPlugin」插入即可，其他不要動。

---

## 3) Info.plist（通常不用改）

使用 UIDocumentPicker 選資料夾一般不需要額外權限字串。
若你另外加了相簿/檔案權限，照原本設定即可。

---

## 4) 你會看到的效果

- 點「讀取記憶卡」選到 `P-SERIES/21751665` 後
- iOS 會把資料夾複製到 App 的 Application Support
- Flutter 端開始掃描 -> 檔案數、PRS1 檔案數會正常增加
- 不會再卡在「有選到資料夾但讀不到內容」
