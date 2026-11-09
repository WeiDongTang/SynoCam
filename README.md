# SynoCam · 群晖监控系统跨平台 App

> 对标官方 **DS Cam**、功能不更少、先 iOS 后 Android 的 Synology Surveillance Station 客户端。
> 技术栈：**Flutter（Dart）跨平台** · 接入：**官方 Surveillance Station Web API** · 构建产物托管于 GitHub。

---

## 📌 项目状态

| 阶段 | 状态 | 说明 |
|------|------|------|
| Phase 0 · 评估 + UI 设计 | ✅ 已完成 | 技术评估报告 + **UI 定稿（方案 A · Aurora 浅色原生）** |
| Phase 1 · 工程骨架（本次） | ✅ 已完成 | **真实 Flutter 分层工程**：网络层/登录/多画面/单画面 PTZ/摄像机管理·添加·编辑/录像/通知/设置 + CI + i18n + 合规清单 |
| Phase 1.5 · 真机联调 | ⏳ 待 NAS | 接入真实 NAS 验证 SID/RTSP/H.265 链路，替换演示数据 |
| Phase 2 · iOS 全功能/上架 | ⏳ | 同步回放 / 双向语音 / 首页模式 / AirPlay / 提审 |
| Phase 3 · Android 复用 | ⏳ | 复用 90% 业务/UI，补 PiP / ExoPlayer / FCM |

> **图标修复**：本次修复了 UI 原型里「图标显示不全/错位」的根因（57 个 SVG `<symbol>` 缺 `viewBox`，导致 `<use>` 不缩放被裁切），并在 Flutter 工程里建立 `AppIcons` 单一映射表 + `AppIcon` 统一尺寸组件，从架构层面杜绝同类问题。

---

## 📂 仓库结构

```
.
├── synocam/                    # ⭐ Flutter 工程根（本次新增）
│   ├── lib/
│   │   ├── main.dart / app.dart
│   │   ├── core/
│   │   │   ├── network/       # syno_api.dart(纯Dart协议) + syno_client.dart(Dio)
│   │   │   ├── config/        # app_config / feature_flags
│   │   │   ├── storage/       # secure_store（Keychain/Keystore 抽象）
│   │   │   └── theme/         # app_colors + app_icons(统一图标) + app_theme
│   │   ├── data/              # models + repositories
│   │   ├── state/             # app_state.dart (Provider/ChangeNotifier)
│   │   ├── features/          # auth/live/cameras/recordings/notifications/settings/shell
│   │   ├── widgets/           # app_icon.dart (BadgeIcon 等)
│   │   └── l10n/              # intl_zh.arb / intl_en.arb
│   ├── test/core_test.dart    # flutter_test 单元测试
│   ├── tool/verify_core.dart  # 纯 Dart 协议自检（dart run，无需 SDK）
│   ├── pubspec.yaml / l10n.yaml / analysis_options.yaml
│   └── README.md
├── .github/
│   ├── workflows/ci.yml       # analyze+test / build-android / build-ios
│   └── fastlane/Fastfile      # 提审占位（需配签名 Secrets）
├── docs/
│   ├── EVALUATION.md          # 技术评估报告
│   ├── UI_DESIGN.md           # UI 定稿说明
│   ├── ARCHITECTURE.md        # 工程架构与数据流（本次新增）
│   ├── checklists/            # a11y / security / commercialization 合规清单
│   ├── store/                 # 双商店上架元数据 + ASO
│   ├── events.md / ab_test.md # 埋点事件模型 / A-B 方案
│   └── backend/               # BaaS(Supabase) 占位配置
├── ui/
│   ├── index.html             # ⭐ UI 定稿（方案 A），可交互原型（本次修复图标）
│   ├── compare.html           # 历史三方案对比页（B/C 归档）
│   ├── option-b.html / option-c.html
│   └── assets/                # 真实感监控画面 cam1-3.jpg
├── .impeccable.md             # 设计语境
└── README.md
```

---

## 🎯 功能基线（不弱于官方 DS Cam）

详见 [`docs/EVALUATION.md`](docs/EVALUATION.md) 第 3 节。覆盖：登录/QuickConnect/HTTPS/局域网发现、多画面布局(1/1×2/2×2/3×3)、单画面 PTZ/变焦/预设/巡逻/双向语音、时间轴回放(0.25x–5x/关键帧)、录像检索/下载/锁定、快照、事件通知/免打扰、首页模式地理围栏、密码锁/Face ID、硬件解码、许可证管理、AirPlay(iOS)/PiP(Android)、多 codec，**以及摄像机管理 / 添加摄像头 / 编辑摄像头信息**。

---

## 🧱 技术架构（本次落地）

```
UI (Flutter Widgets + Provider)
   │  features/{auth,live,cameras,recordings,notifications,settings}
   ▼
AppState (ChangeNotifier)  ── FeatureFlags
   ▼
Repositories (Auth / Camera / Media)
   ▼
SynoClient (Dio)  ── syno_api.dart (纯 Dart：URL/响应/错误码)
   ▼  auth.cgi 登录取 SID → entry.cgi 带 _sid 调 SYNO.SurveillanceStation.*
Synology NAS · Surveillance Station 9.x (官方公开 Web API)
```

- **协议层已真实验证**：`dart run tool/verify_core.dart` → 28 项断言全通过；纯 Dart 层 `dart analyze` 零问题；30 个 Dart 文件语法/引用一致性全通过。
- 核心 API：`SYNO.API.Auth`、`SYNO.SurveillanceStation.Camera / PTZ / VideoStream / Recording / Event / Snapshot / License / HomeMode`。
- 详见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

---

## 🎨 UI 定稿（方案 A · Aurora 浅色原生）

打开 [`ui/index.html`](ui/index.html) 查看**可交互定稿原型**。设计语言：浅灰底 + 纯白分组卡片 + iOS 蓝 + 大留白；**统一 SVG 线性图标库**（本次已修 viewBox 裁切/错位）。信息架构对齐官方 **5 主 tab + 3 二级页**。

深链直达：`index.html#v-live` / `#v-cam` / `#v-rec` / `#v-alert` / `#v-set` / `#p-single` / `#p-edit` / `#p-add`

---

## 🚀 本地 / CI 运行

```bash
cd synocam
flutter pub get            # 需 Flutter >= 3.24 / Dart >= 3.5
flutter gen-l10n
flutter analyze
dart run tool/verify_core.dart
flutter test
flutter run                # 真机/模拟器
```

`.github/workflows/ci.yml` 已 pin **Flutter 3.24.5**：quality(analyze+test) → build-android(AAB) → build-ios(no-codesign)。

> ⚠️ **诚实边界**：本沙箱仅自带 Flutter 3.0.0 / Dart 2.17 且无 Xcode/Android SDK，无法真实编译/打包/提审。协议层已在本机真实执行验证；UI 层的完整 `flutter analyze`/构建/上架需在**开发者本地或 CI**（工作流已配好）执行。原生 iOS 工程需在本地用 Xcode 补全 Signing。

---

## 🔗 GitHub

本地 git 仓库已就绪（含多次提交）。**远程仓库创建与推送待你提供**具备 `repo` 权限的 GitHub Token（之前选定「我帮你建仓库并推送」）。

---

*本项目仅使用 Synology 公开 API，不逆向私有协议；App 名称与图标为独立品牌，规避 Synology 商标。*
