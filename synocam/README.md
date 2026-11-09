# SynoCam · Flutter 工程

群晖监控客户端（对标官方 DS Cam），接入 Synology **Surveillance Station 官方公开 Web API**。
iOS 优先、后续 Android，同一套 Dart 代码复用 UI 与业务逻辑。

- **SDK 基线**：Flutter `>= 3.24` / Dart `>= 3.5`（CI pin `3.24.5`）
- **包名**：`com.synocam.synocam`
- **状态**：Phase 1 工程骨架（可编译运行的分层结构，演示数据；待接入真实 NAS 联调）

---

## 快速开始

```bash
flutter pub get
flutter gen-l10n          # 生成 AppLocalizations（intl_zh/en.arb）
flutter analyze
dart run tool/verify_core.dart   # 无需 Flutter SDK 也能跑：28 项协议断言
flutter test
flutter run
```

首次构建原生壳工程（脚本/CI 已处理）：

```bash
flutter create --platforms=android,ios --project-name synocam --org com.synocam .
flutter build appbundle --release          # Android
flutter build ios --release --no-codesign  # iOS（签名另配）
```

---

## 目录结构

| 目录 | 职责 |
|------|------|
| `lib/core/network` | `syno_api.dart` 纯 Dart 协议（URL/响应/错误码，可单测）；`syno_client.dart` Dio 客户端（登录取 SID、_sid 注入、PTZ/快照/流） |
| `lib/core/config` | 常量、超时、布局/倍速档位、功能开关 |
| `lib/core/storage` | 安全存储抽象（当前内存实现；生产替换 flutter_secure_storage → Keychain/Keystore） |
| `lib/core/theme` | `app_colors` Design Token（对齐 UI 定稿 A）、`app_icons` **统一图标表**、`app_theme` 明暗主题 |
| `lib/data` | `models`（Camera/Recording/Event/Session）+ `repositories`（Auth/Camera/Media） |
| `lib/state` | `app_state.dart` ChangeNotifier，串联会话/摄像机/筛选/PTZ |
| `lib/features` | `auth` `live`(多画面+单画面 PTZ/时间轴) `cameras`(列表/编辑/添加) `recordings` `notifications` `settings` `shell` |
| `lib/widgets` | `AppIcon` / `BadgeIcon`：统一图标尺寸与色调，杜绝错位 |
| `lib/l10n` | 中英 ARB 资源 |
| `test` | 协议/模型/开关单元测试 |
| `tool` | `verify_core.dart` 纯 Dart 自检脚本 |

---

## 关键设计约定

1. **图标唯一入口**：所有图标只能来自 `AppIcons.*`，且经 `AppIcon`/`BadgeIcon` 渲染（固定尺寸/线宽）。禁止页面里散写 `Icons.xxx` 或 emoji —— 这是修复原型「图标不统一/裁切/错位」的架构级措施。
2. **凭据零落地**：账号/密码/SID 只经 `SecureStore`，绝不写 SharedPreferences 明文或硬编码。见 `docs/checklists/checklist-security.md`。
3. **协议与业务分离**：`syno_api.dart` 不依赖 Flutter/dio，可在任意 Dart 环境单测；`SynoClient` 只做协议胶水；语义由 Repository 组装。
4. **会话失效统一处理**：错误码 106/107/402 → `SynoException.needsReLogin`，UI 触发重新登录。
5. **敏感资产**：证书/签名/keystore/API 密钥一律走环境变量与 CI Secrets，仓库不含明文。

---

## 构建未签名 iOS IPA

> iOS 编译**只能在 macOS + Xcode** 上完成。CI（`.github/workflows/ci.yml`）的 `build-ios` job 用 `macos-latest` runner 自动产出，产物为 Actions artifact `synocam-ios-unsigned-ipa`。

**本地（macOS + Xcode + Flutter 3.24.x）：**

```bash
cd synocam
bash scripts/build_unsigned_ipa.sh
# → build/ipa/SynoCam-unsigned.ipa
```

脚本内部流程：`pub get` → `gen-l10n` → `create ios`（首次）→ `build ios --release --no-codesign` → 把 `Runner.app` 按 `Payload/` 结构 `zip` 成 `.ipa`。

**关于「未签名」**：该 ipa 的 `Runner.app` 不含签名与 `embedded.mobileprovision`，**不能直接装到未越狱真机**。用途是后续用你自己的开发者/企业证书重签名（`codesign` / `fastlane sigh` + `resign`），或归档、越狱分发、二次打包。正式上架请用 `flutter build ipa` 配合签名证书与 App Store Connect（见 `.github/fastlane/Fastfile`、`docs/store/`）。

> CI 里 `build-ios` **刻意不依赖** `quality` 门禁：macOS runner 排队久，让 ipa 与质量门禁并行，先把产物产出。

---

## 已知边界（Phase 1 骨架）

- 快照轮询用于预览；**直播**目前给 MJPEG URL 骨架，生产需接 RTSP + 原生播放器（AVPlayer/ExoPlayer/VLC）实现 H.265 硬解、双向语音、PiP。
- 事件/录像列表在真实数据为空时回落到演示数据，保证页面可评审；接入 NAS 后自动用真实数据。
- 删除摄像机以「停用」代替物理删除（对齐官方，物理删除在 SS 网页端）。
- 仅 Synology 品牌摄像头可在 App 内添加；第三方 IP 摄像头需先在 SS 网页端配置。
- 完整编译/打包/提审需 Xcode（iOS）与 Android SDK，在本仓库 CI（已配 Flutter 3.24.5）或开发者本地执行。

---

*仅使用 Synology 公开 Web API，不逆向私有协议；独立品牌，规避商标。*
