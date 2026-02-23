# 💤 睡到寶 PRS1

### Philips DreamStation 開源睡眠治療數據分析工具

iOS App + Open Source Project

App Store:
https://apps.apple.com/us/app/%E7%9D%A1%E5%88%B0%E5%AF%B6/id6759235114

GitHub: https://github.com/8xespace/PRS1_CPAP

------------------------------------------------------------------------

## 📱 App 簡介

「睡到寶 PRS1」是一款專為 Philips DreamStation (PRS1)
陽壓呼吸治療設備所設計的睡眠數據分析工具。

可直接讀取 SD 卡資料，於 iPhone / iPad 上顯示完整睡眠治療統計圖表：

-   AHI 呼吸中止指數
-   氣流速率 (Flow Rate)
-   壓力 (Pressure / EPAP)
-   漏氣率 (Leak Rate)
-   呼吸容量 (Tidal Volume)
-   呼吸速率 (Respiratory Rate)
-   分鐘通氣率 (Minute Ventilation)
-   鼻鼾 VS / VS2 事件標記
-   交叉分析圖 (Cross Analysis)

------------------------------------------------------------------------

## 🧠 設計理念

本專案目標：

> 在 iPad 上建立接近桌面級 OSCAR 的專業分析能力\
> 同時保持 iOS 原生流暢度與低記憶體占用

設計原則：

-   ✔ 以 OSCAR 為對齊基準進行數據驗證
-   ✔ 嚴格控制 35 天資料載入範圍（避免 iPad OOM）
-   ✔ Header 準濾（Header Gating）機制
-   ✔ 動態 Y 軸醫療級刻度設計
-   ✔ iPhone / iPad 分模式顯示
-   ✔ 全本地端處理，無雲端依賴

------------------------------------------------------------------------

## 🔒 重要聲明

-   本應用程式不是醫療診斷工具\
-   不替代醫師專業建議\
-   數據準確性取決於設備輸出格式\
-   僅供個人治療成果觀察與參考

------------------------------------------------------------------------

## 🏗 技術架構

### 前端

-   Flutter (Web + iOS)
-   CustomPainter 圖表引擎
-   iPad 專用佈局模式

### iOS 原生層

-   Swift + MethodChannel
-   Security-Scoped Bookmark
-   沙盒資料夾複製策略

### 記憶體優化

1.  讀取檔案 header 512\~2048 bytes
2.  抽取 timestamp
3.  35 天 Gate 篩選
4.  合格檔案才 full decode
5.  延遲載入圖表
6.  清除 working set

------------------------------------------------------------------------

## 📊 與 OSCAR 對齊

-   PRS1 binary chunk 解析
-   呼吸切割模型
-   AHI 計算邏輯
-   Leak threshold 判斷
-   Pressure 時間對齊
-   Insp / Exp 時間模型

------------------------------------------------------------------------

## 📂 開源精神

本專案基於 GNU GPL v3 License。

歡迎：

-   Fork
-   Issue
-   Pull Request

------------------------------------------------------------------------

## 📌 平台支援

  平台        支援狀態
  ----------- ------------------
  iPhone      統計摘要模式
  iPad        完整專業分析模式
  Web Debug   開發測試環境

------------------------------------------------------------------------

❤️ 致謝

-   OSCAR 開源社群:
https://gitlab.com/CrimsonNape/OSCAR-code

-   睡眠治療使用者
-   iPad 重度使用測試

------------------------------------------------------------------------

# 💤 SleepToBao PRS1

### Philips DreamStation Sleep Therapy Data Analyzer

iOS App + Open Source Project

App Store:
https://apps.apple.com/us/app/%E7%9D%A1%E5%88%B0%E5%AF%B6/id6759235114

GitHub: https://github.com/8xespace/PRS1_CPAP

------------------------------------------------------------------------

## 📱 Overview

SleepToBao PRS1 is a professional sleep therapy data analysis tool
designed for **Philips DreamStation (PRS1)** CPAP devices.

The app reads SD card data directly and provides comprehensive therapy
statistics on **iPhone and iPad**, including:

-   AHI (Apnea--Hypopnea Index)
-   Flow Rate
-   Pressure (Pressure / EPAP)
-   Leak Rate
-   Tidal Volume
-   Respiratory Rate
-   Minute Ventilation
-   Snore Events (VS / VS2)
-   Cross Analysis Charts

------------------------------------------------------------------------

## 🧠 Design Philosophy

The goal of this project is not just to display raw data, but:

> To deliver near-desktop-level OSCAR-style professional analysis on
> iPad\
> While maintaining native iOS smoothness and strict memory control

Core principles:

-   ✔ Data alignment and validation against OSCAR
-   ✔ Strict 35-day data loading window (OOM prevention on iPad)
-   ✔ Header-based pre-filtering (Header Gating)
-   ✔ Dynamic medical-grade Y-axis scaling
-   ✔ Dedicated iPhone / iPad layout modes
-   ✔ Fully local processing (no cloud dependency)

------------------------------------------------------------------------

## 🔒 Disclaimer

-   This application is NOT a medical diagnostic tool.
-   It does NOT replace professional medical advice.
-   Data accuracy depends on manufacturer file formats.
-   Generated statistics are for personal reference only.

------------------------------------------------------------------------

## 🏗 Technical Architecture

### Frontend

-   Flutter (Web + iOS)
-   High-performance CustomPainter chart engine
-   iPad-optimized professional layout

### Native iOS Layer

-   Swift + MethodChannel
-   Security-Scoped Bookmarks
-   Sandboxed folder copy strategy

### Memory Optimization Strategy

To prevent iPad Out-Of-Memory issues:

1.  Read only file headers (512--2048 bytes)
2.  Extract timestamps
3.  Apply 35-day Gate filtering
4.  Full decode only for qualified files
5.  Lazy-load chart modules
6.  Clear working sets aggressively

Validated on:

-   Web Debug
-   iPhone
-   iPad

------------------------------------------------------------------------

## 📊 Alignment with OSCAR

Reverse-engineered and validated against OSCAR for:

-   PRS1 binary chunk parsing
-   Breath segmentation logic
-   AHI calculation
-   Leak threshold modeling
-   Pressure timeline alignment
-   Inspiration / Expiration time modeling

All statistical models cross-validated with PRS1.zip and sample data.zip
datasets.

------------------------------------------------------------------------

## 📂 Open Source

This project is released under **GNU GPL v3 License**.

Contributions welcome:

-   Fork
-   Issue submissions
-   Pull Requests
-   Technical discussions

------------------------------------------------------------------------

## 📌 Platform Support

  Platform    Status
  ----------- ----------------------------
  iPhone      Summary Mode
  iPad        Full Professional Analysis
  Web Debug   Development Environment
