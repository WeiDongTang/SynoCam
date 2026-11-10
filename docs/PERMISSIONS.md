# SynoCam 系统权限清单

本文件说明 App **实际声明并请求**的手机系统权限、对应用途、双平台差异，以及用户如何查看与撤销。

所有权限都由 CI 在 `flutter create` 动态生成原生壳之后，通过
[`synocam/scripts/apply_native_config.py`](../synocam/scripts/apply_native_config.py) 注入到
`ios/Runner/Info.plist`、`ios/Runner/AppDelegate.swift`、`android/app/src/main/AndroidManifest.xml`
与 `MainActivity.kt`。脚本带落盘自检，注入失败会让 CI 直接变红，不会出现「以为配了其实没配」。

App 内的「设置 → 系统权限」卡片显示的是**通过 MethodChannel 读到的真实系统状态**，
不是本地写死的展示值；「请求通知权限」「打开系统设置」「刷新状态」均为真实系统行为。

## iOS

| 权限 / 配置 | 声明位置 | 运行时行为 | 用途 |
|---|---|---|---|
| 通知授权（提醒 / 角标 / 声音） | `AppDelegate.swift` → `UNUserNotificationCenter.requestAuthorization` | 首次启动弹系统授权框；设置页可再次请求 | Surveillance Station 事件提醒 |
| `UIBackgroundModes = fetch, remote-notification` | `Info.plist` | 系统后台刷新时机 | 事件列表刷新、未来接入远程通知 |
| `NSLocalNetworkUsageDescription` | `Info.plist` | iOS 13+ 访问局域网时弹一次授权 | 发现局域网内的 NAS / 摄像头（DDNS 回环场景常见） |
| `NSPhotoLibraryAddUsageDescription` | `Info.plist` | 写相册前系统校验 | 保存监控快照与录像片段 |
| `NSAppTransportSecurity.NSAllowsLocalNetworking = true` | `Info.plist` | 无弹窗 | 允许局域网明文 HTTP；**未**开放 `NSAllowsArbitraryLoads`，公网仍强制 ATS |
| `ITSAppUsesNonExemptEncryption = false` | `Info.plist` | 无 | 明确不使用非豁免加密，避免提审重复填写出口合规问卷 |
| 自签名 HTTPS 证书 | 代码层 `cert_policy.dart` + `HttpOverrides` | 由设置页「信任自签名 HTTPS 证书」开关控制 | 自有 NAS 的自签证书；**不是**放宽全局 ATS |

> iOS 通知授权不需要 `Info.plist` 描述键，靠运行时 `requestAuthorization` 完成。
> 远程推送（APNs）需要 `aps-environment` entitlement 与开发者推送证书；
> Surveillance Station Web API 本身不提供原生推送通道，因此本版本**只做本地通知授权**，
> 不声明「已支持远程推送」。App 内通知页展示的是从 `Event/Query` 读取的真实录像/告警事件。

## Android

| 权限 | 声明位置 | 运行时行为 | 用途 |
|---|---|---|---|
| `INTERNET` | `AndroidManifest.xml` | 无需运行时授权 | 连接 NAS（Flutter 模板已声明，脚本幂等跳过重复） |
| `ACCESS_NETWORK_STATE` | `AndroidManifest.xml` | 无需运行时授权 | 判断网络可达性，弱网时给出准确提示 |
| `POST_NOTIFICATIONS` | `AndroidManifest.xml` + `MainActivity.kt` | **Android 13+ 首次启动 `requestPermissions`** | 事件通知；13 以下无需运行时授权 |
| `VIBRATE` | `AndroidManifest.xml` | 无需运行时授权 | 通知震动 |
| `WAKE_LOCK` | `AndroidManifest.xml` | 无需运行时授权 | 连续流播放时保持唤醒 |
| `WRITE_EXTERNAL_STORAGE` (`maxSdkVersion=28`) | `AndroidManifest.xml` | 仅 API ≤28 | 保存快照；API 29+ 走 MediaStore，不申请宽泛存储权限 |

> Android 13（API 33）以下 `notificationStatus()` 返回 `granted`，因为系统不要求运行时通知授权，
> 这不是伪造状态，而是平台行为差异。

## 权限通道（Dart ↔ 原生）

`lib/core/platform/permissions.dart` 通过 `MethodChannel('com.synocam/permissions')` 暴露三个方法：

| 方法 | 返回 | 原生实现 |
|---|---|---|
| `notificationStatus` | `granted` / `denied` / `notDetermined` / `unknown` | iOS `getNotificationSettings`；Android `checkSelfPermission` |
| `requestNotifications` | 同上 | iOS `requestAuthorization`；Android `requestPermissions(POST_NOTIFICATIONS)` |
| `openSettings` | `ok` / `unavailable` | iOS `UIApplication.openSettingsURLString`；Android `ACTION_APPLICATION_DETAILS_SETTINGS` |

只用 Flutter SDK 自带的 `MethodChannel`，**未引入** `permission_handler` /
`flutter_local_notifications` 等第三方插件 —— 它们会拉起额外 iOS Pod，在 Flutter 3.24.5 /
iOS 12 部署目标下可能与 `video_player` 触发 `pod install` 的 SDK 版本冲突。

## 用户如何查看 / 撤销

- **App 内**：设置 → 系统权限 → 查看真实状态、重新请求授权、打开系统设置。
- **iOS**：系统设置 → 群晖监控 → 通知 / 本地网络 / 照片。撤销后 App 内状态点「刷新状态」即同步。
- **Android**：系统设置 → 应用 → SynoCam → 权限 / 通知。

## 未申请的权限（刻意为之）

| 权限 | 原因 |
|---|---|
| 精确定位 / 后台定位 | App 不需要地理位置，DS Cam 也不需要 |
| 通讯录 / 相机 / 麦克风 / 蓝牙 | 本版本无对讲、无扫码配对、无外设能力 |
| 完整相册读取（`NSPhotoLibraryUsageDescription`） | 只需写入相册，采用更克制的 `…AddUsageDescription` |
| `NSAllowsArbitraryLoads` | 公网仍强制 ATS 安全策略，自签证书由代码层按用户开关处理 |
| 推送 entitlement / APNs | SS Web API 无原生推送通道，不做无法兑现的声明 |
