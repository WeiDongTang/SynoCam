# SynoCam · 工程架构与数据流（Phase 1）

> 配套：`/synocam` Flutter 工程 · 技术评估报告 `EVALUATION.md` · UI 定稿 `UI_DESIGN.md`

---

## 1. 分层架构

```
┌──────────────────────────────────────────────────────────┐
│ Presentation  · lib/features + lib/widgets                │
│   AppShell(5 tab) / LoginPage / LivePage / SingleViewPage  │
│   CamerasPage / EditPage / AddPage / Recordings / Events / Settings │
│   —— 只用 AppIcons.* + AppIcon/BadgeIcon 渲染图标           │
└───────────────┬──────────────────────────────────────────┘
                │ context.watch / read
┌───────────────▼──────────────────────────────────────────┐
│ State  · AppState (ChangeNotifier + Provider)             │
│   session / cameras / filter / grid / events / feature flags│
└───────────────┬──────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────┐
│ Data  · repositories (Auth/Camera/Media) + models          │
│   原始 JSON → 领域模型（字段别名兼容）→ 语义方法            │
└───────────────┬──────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────┐
│ Network  · SynoClient (Dio) + syno_api.dart (纯 Dart)      │
│   buildSynoUrl / SynoResponse / SynoException / 错误码映射  │
└───────────────┬──────────────────────────────────────────┘
                │ HTTPS / HTTP (5000/5001)
       Synology NAS · Surveillance Station 9.x
```

**依赖方向单向向下**：UI 不直接碰 Dio，网络层不 import Flutter。`syno_api.dart` 因此可在无 SDK 环境单测。

---

## 2. 认证与调用链路

```
1) auth.cgi?api=SYNO.API.Auth&method=login&version=6
           &account=&passwd=&session=SurveillanceStation&format=sid
   ← { success:true, data:{ sid, did } }        失败 ← error.code(400/403/404/…)
2) 之后所有调用 entry.cgi?api=SYNO.SurveillanceStation.<X>&version=N
           &method=<M>&_sid=<sid>&…
3) 106/107/402 → SynoException.needsReLogin → UI 回登录页
4) logout → Auth/logout + 清空 SecureStore
```

- 端口：HTTP `5000` / HTTPS `5001`；host 自带 `https://` 自动切 5001。
- `otp_code` 支持两步验证（DSM 返回 404/405 时登录页自动展开 OTP 输入）。
- 版本以 `SYNO.API.defaultVersions` 兜底，生产应先用 `SYNO.API.Info/query` 协商 maxVersion。

### 核心 API 映射

| 能力 | api | method |
|------|-----|--------|
| 摄像机列表 | `SYNO.SurveillanceStation.Camera` | `List` |
| 快照 / 启用停用 | 同上 | `GetSnapshot` / `Enable` / `Disable` |
| 改名/流质量 | 同上 | `Save` |
| PTZ | `SYNO.SurveillanceStation.PTZ` | `Move` / `Zoom` / `GoPreset` / `ListPreset` |
| 直播流 | `…Stream.VideoStreaming` | `Stream`(mjpeg，含 StmKey) |
| 录像 | `…Recording` | `List` / `Lock` / `Unlock` / `Download` / `Delete` |
| 事件 | `…Event` | `List` |
| 许可证 / 首页模式 | `…License` / `…HomeMode` | — |

> 依据 Synology 官方 Web API 与 DSM `SYNO.API.*` 通用约定；字段做了多版本别名兼容（`id`/`cameraId`、`name`/`newName`、`camModel`…）。

---

## 3. 统一图标系统（针对「图标不统一/错位」）

原型 Round 3 曾出现图标风格不一、裁切、错位，根因两层：
- **HTML 层**：57 个 `<symbol>` 缺 `viewBox="0 0 24 24"`，`<use>` 引用时按 24 单位画进 20px 容器被裁切 → 本次已全部补齐并 8 页截图核验。
- **Flutter 层（架构级预防）**：
  - `core/theme/app_icons.dart` = **唯一** `IconData` 映射表（58 个，SF-Symbols 风格 Material 线性图标）。
  - `widgets/app_icon.dart` = `AppIcon`（固定尺寸/色）+ `BadgeIcon`（统一圆角色块）。
  - 约定：**禁止在页面散写 `Icons.xxx`/emoji**；数据驱动的事件图标走 `iconForEventType()`。
  - 已用脚本自检：所有 `AppIcons.*` 引用均有定义、零缺失。

---

## 4. Design Token → 主题

`ui/index.html` 定稿 A 的 CSS 变量一一映射到 `app_colors.dart`：

| 原型变量 | Flutter Token | 值 |
|---------|---------------|-----|
| `--bg` | `AppColors.bg` | `#EDEEF1` |
| `--card` | `AppColors.card` | `#FFFFFF` |
| `--ink` | `AppColors.ink` | `#15181E` |
| `--blue` | `AppColors.blue` | `#1C6BF2` |
| `--green/red/amber` | 状态色 | 在线/告警/待机 |
| `--sh` / 圆角 15 | `CardThemeData` / `BorderRadius` | 柔和悬浮 |

`app_theme.dart` 用 `WidgetState*` / `CardThemeData` 构建明暗主题，iOS Large Title、分段控件、grouped list 由各页面 widget 还原。

---

## 5. 质量保障与验证结果（本机实测）

| 验证项 | 命令 | 结果 |
|--------|------|------|
| 协议/模型/开关逻辑 | `dart run tool/verify_core.dart` | ✅ 28 项断言通过 |
| 纯 Dart 层静态分析 | `dart analyze <core/config,network,storage,models,tool>` | ✅ No issues found |
| 全量语法可解析 | `dart format --output=none lib tool test` | ✅ 30 文件无 parse error |
| 引用一致性 | 自检脚本（相对 import / package:synocam / AppIcons / 依赖声明） | ✅ 全通过 |
| ARB / YAML 合法性 | json/yaml 解析 + 中英 key 集合比对 | ✅ 通过 |
| UI 原型图标渲染 | 无头 Chromium 8 页截图 | ✅ 完整/居中/一致 |

**未在本机完成**：`flutter analyze`（全 UI）、`flutter build`、`flutter test`（需 `package:flutter` + 现代 SDK）。
本机仅 Flutter 3.0.0 / Dart 2.17，低于工程 `>=3.5` 约束且无 Xcode/Android SDK。
→ 由 `.github/workflows/ci.yml`（pin Flutter 3.24.5）在 CI 完成：analyze / 自检 / test / build-android(AAB) / build-ios(no-codesign)。

---

## 6. 工程化配套

| 产物 | 路径 | 说明 |
|------|------|------|
| CI/CD | `.github/workflows/ci.yml` | quality → android → ios 三 job，pin Flutter 3.24.5 |
| Fastlane | `.github/fastlane/Fastfile` | 提审占位，需配签名/ASC/Play Secrets |
| i18n | `synocam/lib/l10n/intl_{zh,en}.arb` + `l10n.yaml` | zh/en，MaterialApp 已挂 delegates |
| 合规清单 | `docs/checklists/checklist-{a11y,security,commercialization}.md` | 无障碍/安全个保法/商业化 |
| 上架元数据 | `docs/store/{app-store,google-play}` + `aso-report.md` | 双商店文案/关键词/截图规格 |
| 功能开关 | `synocam/lib/core/config/feature_flags.dart` | 本地默认 + 远程覆盖，灰度/回滚 |
| 埋点/AB | `docs/events.md` / `docs/ab_test.md` | 事件模型与实验方案 |
| BaaS | `docs/backend/` | Supabase 占位（推送/崩溃/远程配置） |

---

## 7. 风险与后续（诚实边界）

1. **视频链路**：MJPEG 骨架仅用于预览；生产必须接 RTSP + 原生播放器插件（AVPlayer/ExoPlayer/VLC）实现 H.265 硬解、双向语音、PiP、低时延。这是「不弱于官方」的最大工程量。
2. **真机联调**：需一台 DSM 7.x + SS 9.x NAS 验证 SID、GetSnapshot、Stream、PTZ 实际字段与错误码。
3. **签名/上架**：iOS 需 `.xcodeproj` Signing + App Store Connect；Android 需 keystore。CI 已给 `--no-codesign` 构建，签名在 fastlane。
4. **安全存储**：当前 `InMemorySecureStore` 为可编译占位，上线前替换为 `flutter_secure_storage`（Keychain/Keystore）。
5. **私有协议**：全程仅用公开 API，不逆向 DS Cam 私有通信；个别官方私有能力（如深度 DVA）可能无法 1:1 复刻，已在评估报告标注。
