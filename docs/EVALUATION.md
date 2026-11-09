# 群晖监控系统手机 App 重开项目 · 技术评估报告

> 代号：**SynoCam**（暂定，可改）
> 版本：v0.2（Phase 1 工程骨架已落地） · 日期：2026-11-09
> 目标：以 Flutter 跨平台方案重开一款功能**不弱于**官方 DS Cam 的监控 App，先发 iOS、后复用到 Android；接入走 Synology 官方公开的 **Surveillance Station Web API**；构建产物托管于 GitHub。

> **落地更新（Phase 1）**：`/synocam` 已产出真实可编辑的 Flutter 分层工程（网络层/登录/多画面/单画面 PTZ/摄像机管理·添加·编辑/录像/通知/设置）+ CI + i18n + 合规/上架/埋点配套。协议层 28 项断言本机真实跑通、纯 Dart 层 `dart analyze` 零问题、30 文件语法与引用一致性全通过。架构与数据流详见 [`ARCHITECTURE.md`](ARCHITECTURE.md)；完整编译/打包/提审由 pin Flutter 3.24.5 的 CI 完成（本机 SDK 过旧且无 Xcode）。

---

## 1. 结论先行（TL;DR）

| 维度 | 结论 |
|------|------|
| 可行性 | **高**。官方 Web API 已覆盖登录、相机列表、快照、PTZ、录像检索、事件、直播路径等核心能力，足够支撑功能等价。 |
| 技术栈 | **Flutter（Dart）跨平台**——一套代码覆盖 iOS + Android，视频通过原生平台通道 / 成熟插件桥接，后续安卓几乎零额外成本。 |
| 接入方式 | **官方 Surveillance Station Web API**（HTTP + Session 鉴权）。合规、可维护、文档齐全；个别私有能力（如极致低延迟）可接受小幅妥协。 |
| 最大风险 | 视频解码（H.264/H.265/RTSP 低延迟）、双向语音、推送通道、iOS AirPlay / Android PiP 等需原生能力，是工作量与难度的集中点。 |
| 工作量 | iOS MVP ≈ 6–8 周；iOS 全功能 ≈ 4–5 个月；Android 复用期 ≈ 4–6 周（主要补平台差异）。合计约 6–8 人月。 |
| 建议 | **先交付 iOS MVP（登录 + 多画面 + 单画面 + 录像/快照 + 通知）**，跑通官方 API 与视频链路后再补齐管理类功能，安卓并行复用。 |

---

## 2. 目标与范围

- **必须满足**：功能集合 ⊇ 官方 DS Cam（详见第 3 节基线）。
- **平台路线**：iOS 优先（最低部署 iOS 15，对齐官方），Android 8.0+ 后续复用。
- **接入约束**：优先官方公开 API；不逆向私有协议（规避法律与维护风险）。
- **交付物**：本阶段为「评估报告 + UI 设计稿 + 仓库骨架」；后续阶段才落地完整 Flutter 工程。
- **非目标**：不在 App 内实现录像存储/AI 分析等 NAS 侧能力，仅做客户端呈现与控制。

---

## 3. 官方 DS Cam 功能基线（等价对照表）

下表为「不能更少」的硬性清单，是后续验收的基准。

### 3.1 登录与连接
- [x] QuickConnect ID / IP / DDNS 登录
- [x] HTTPS（SSL/TLS）+ 自签名证书手动信任
- [x] 局域网自动发现（mDNS/SSDP）
- [x] 登录历史 + "Remember me" + 多账号切换
- [x] 2FA 兼容（OTP 二次校验 + 信任此设备免验证码）

> **Phase 1 落地补记（2FA）**：按 Synology《DSM Login Web API Guide》官方错误码实现完整
> 闭环 —— 403「需要验证码」/404「验证码失败」/406「强制 2FA」→ 登录页自动展开 OTP
> 输入框；首次 `otp_code`+`enable_device_token=yes` 成功返回 `did` 后按 `host|account`
> 持久化，后续仅带 `device_id` 免验证码登录。修正了早期把 403 误标「密码错误」、
> 用 404/405 判定「需要 2FA」导致 2FA 账号登录报错且 OTP 框不弹出的缺陷。
> UI 原型新增 `p-login` 演示页（`#p-login` 直达，设置页「账户与服务器」入口）。

### 3.2 多画面（Multi View）
- [x] 布局 1×2 / 1×3 / 2×2 / 2×3，自定义相机与顺序
- [x] 同步回放（sync-mode timeline）
- [x] 播放速度 0.25x–5x，关键帧快放
- [x] 快捷面板：播放控制 / 事件切换 / 快速定位 / 快照 / PTZ / 光学变焦 / 时间轴 / 双向语音 / 手动录像 / 固定比例
- [x] 拖动时间轴回看、Smart Timeline 自动缩放

### 3.3 单画面（Single View）
- [x] PTZ 控制、光学变焦、预设位 / 巡逻 / 自动扫描
- [x] 双向语音（对讲）
- [x] 手动快照、手动录像
- [x] 画质切换、数字输出、预设位等（依设备能力动态显示）
- [x] 静音切换、Mute/Unmute
- [x] Android PiP 画中画（iOS 侧以原生画中画或悬浮窗替代）

### 3.4 摄像机（Cameras）
- [x] 列表 / 缩略图切换、排序
- [x] 启 / 停相机、关键字 / 来源 / 状态搜索
- [x] 基础信息展示、悬浮播放器（离开页面持续播放）
- [x] **添加新摄像头**：局域网自动发现 Synology Camera（型号/序列号/IP）、二维码配网（Wi-Fi 加密 None/WPA/WPA2/WPA3、DHCP）、手动添加；第三方相机须先在 Surveillance Station 网页端配置
- [x] **编辑摄像头信息**：名称、启用/停用、流质量、数字输出、预置位 / 巡逻、录像模式、删除
- [x] 许可证额度提示

> UI 落地状态：定稿原型 `ui/index.html` 的「摄像机」tab + 「编辑摄像机」「添加摄像头」二级页已覆盖以上全部能力（详见 `UI_DESIGN.md`）。

### 3.5 录像（Recordings）
- [x] 按日期 / 时间 / 来源 / 相机 / 锁定状态 / 录制模式检索
- [x] 删除 / 锁定 / 解锁 / 下载、时长截取下载、片段预览
- [x] 当前帧快照、0.25x–5x 变速、静音切换
- [x] 悬浮播放器

### 3.6 快照（Snapshots）
- [x] 浏览、按日期 / 锁定状态检索
- [x] 删除 / 锁定 / 解锁 / 下载

### 3.7 通知（Notifications）
- [x] 事件推送（系统 / 相机 / I/O / 门禁 / Deep Video Analytics / 归档库等）
- [x] 临时免打扰（20 分钟 / 1 / 2 / 4 / 8 小时 / 当日结束）
- [x] Do Not Disturb 时段、缩略图跳单画面、关键字 / 已读检索

### 3.8 首页模式（Home Mode）
- [x] 按位置（GPS）或 Wi-Fi SSID 自动激活
- [x] 地图选点 + 半径（100–500m）+ 触发延迟（30s/1/2/3min）
- [x] 多设备配对、手动进/出首页模式

### 3.9 安全与系统
- [x] 4 位密码锁 + Touch ID / Face ID + 超时重验
- [x] 受信连接管理
- [x] 硬件解码（H.264/H.265）、权限配置（privilege profile）
- [x] 许可证查看 / 添加 / 删除、离线许可证管理
- [x] iOS AirPlay 镜像（整屏 / 仅视频）
- [x] 支持 codec：MJPEG、H.264、H.264+、H.265、H.265+、MPEG4、MxPEG

---

## 4. 技术选型评估：为何选 Flutter

| 方案 | 视频性能 | 双端复用 | 开发速度 | 结论 |
|------|---------|---------|---------|------|
| **Flutter（推荐）** | 原生通道 + `flutter_vlc_player`/`media_kit` 桥接，可达 RTSP/H.265 | **一套代码 90%+ 复用** | 快 | ✅ 满足"先 iOS 后安卓"且要等价 |
| 原生 SwiftUI + Kotlin | 最佳 | 低（两套） | 慢 | 仅在对视频极致要求时考虑 |
| React Native | 原生模块桥接 | 高 | 中 | 可行，但视频插件生态略弱于 Flutter |

**决策**：Flutter。视频这一"重"部分用平台通道（Platform Channel）调用 iOS `AVPlayer` / Android `ExoPlayer` 或集成 VLC 引擎，UI 与业务逻辑全跨端共享。

> 注意：官方 DS Cam 是原生 App（89.6 MB，体验打磨深）。Flutter 在"列表/时间轴/设置"等 UI 上等价甚至更快，真正的差距只在**超低延迟直播**与**系统级集成**（AirPlay/PiP/后台推送），这些用原生通道补齐即可。

---

## 5. 接入方式评估：官方 Surveillance Station Web API

### 5.1 协议骨架
```
1. SYNO.API.Info  → 发现各 API 的入口与版本
2. SYNO.API.Auth → Login(session=SurveillanceStation) → 返回 Session Cookie / sid
3. 业务 API       → 携带 _sid / Cookie 调用
4. SYNO.API.Auth → Logout
```
- 传输：`http://host:5000/webapi/...` 或 `https://host:5001/webapi/...`
- 鉴权：`session=SurveillanceStation`，支持 Cookie 或 `_sid` 查询参数
- 响应：统一 `{success, data, error:{code}}` JSON

### 5.2 关键 API 与功能映射

| 功能 | API |
|------|-----|
| 登录/登出 | `SYNO.API.Auth` (Login/Logout) |
| 服务器信息/能力 | `SYNO.SurveillanceStation.Info` |
| 相机列表/启停/快照/直播路径 | `SYNO.SurveillanceStation.Camera` (List/Enable/Disable/GetSnapshot/**GetLiveViewPath**) |
| PTZ/预设/巡逻 | `SYNO.SurveillanceStation.PTZ` |
| 直播视频流 | `SYNO.SurveillanceStation.VideoStream` / `Streaming`（mjpeg / 经路径拿 RTSP/HTTP-FLV） |
| 直播音频流（双向语音） | `SYNO.SurveillanceStation.AudioStream` |
| 录像检索/下载 | `SYNO.SurveillanceStation.Recording` / `ExternalRecording` |
| 事件/通知查询 | `SYNO.SurveillanceStation.Event` |
| 推送令牌注册 | `SYNO.SurveillanceStation.Notification` |
| 电子地图 | `SYNO.SurveillanceStation.Emap` |
| 门禁/VisualStation | `SYNO.SurveillanceStation.Device` |
| 许可证 | `SYNO.SurveillanceStation.License`（若公开） |

### 5.3 直播流的现实路径（关键）
- `GetLiveViewPath` 返回带 `StmKey` 的播放路径，格式可为 **mjpeg** 或 **RTSP/HTTP-FLV**（依相机编码与 SS 配置）。
- **MJPEG**：可直接用 `VideoStreaming?format=mjpeg` 在 Flutter 中渲染，兼容性好但码率高、延迟高。
- **H.264/H.265/RTSP**：需要原生播放器。Flutter 侧用 `flutter_vlc_player`（VLC 引擎，支持 RTSP + H.265）或自建 Platform View 封装 `AVPlayer`/`ExoPlayer`，这是全项目**技术难度最高**的一环。

### 5.4 官方 API 的局限（需预案）
- 部分能力（如极致低延迟、Smart Timeline 服务端语义）官方文档未完全公开，可能需结合 `/webapi/entry.cgi` 实测兜底。
- 2FA 账号需实现 OTP 二次登录流程。
- 推送依赖 Synology 官方推送服务，需注册设备 token 到 `Notification` API；自建推送通道（APNs/FCM）仅能覆盖"事件到达 App 后"的本地提醒，**无法替代**服务端事件触发——这一点必须与官方能力对齐说明。

---

## 6. 系统架构设计（建议）

```
┌─────────────────────────────────────────────┐
│                   UI 层 (Flutter)             │
│  MultiView / SingleView / Recordings / ...    │
│  Riverpod / Bloc 状态管理                     │
├─────────────────────────────────────────────┤
│              Domain / 用例层                  │
│  Camera / Recording / Event / HomeMode 实体   │
├─────────────────────────────────────────────┤
│              Repository 层                    │
│  AuthRepo · CameraRepo · StreamRepo · ...     │
├─────────────────────────────────────────────┤
│         API Client (Dio + 拦截器)             │
│  SSWebApiClient: 鉴权/重试/错误码映射         │
├─────────────────────────────────────────────┤
│   原生通道 (Platform Channel / Pigeon)        │
│  VideoPlayer(iOS AVPlayer / Android Exo)      │
│  TwoWayAudio · AirPlay · PiP · Biometrics     │
└─────────────────────────────────────────────┘
         │ HTTPS / RTSP / Stream
         ▼
   Synology NAS · Surveillance Station
```

- **状态管理**：推荐 `Riverpod`（编译安全、测试友好）。
- **网络**：`Dio` + 自定义拦截器（自动注入 `_sid`、统一错误码映射、证书信任策略）。
- **原生桥接**：用 `pigeon` 生成类型安全的 Platform Channel，隔离视频/音频/生物识别/AirPlay。
- **本地存储**：`flutter_secure_storage`（凭据/Token）+ `hive/sqflite`（登录历史、偏好）。
- **CI/CD**：GitHub Actions 出 iOS（需 macOS runner + 签名证书）与 Android（AAB）产物，Release 上传 GitHub Artifacts / Releases。

---

## 7. 功能等价性映射（实现方案速查）

| 官方功能 | 实现方案 |
|---------|---------|
| 登录/QC/HTTPS/发现 | `AuthRepo` + mDNS 发现插件 + 证书信任策略 |
| 多画面网格 | `GridView` 动态布局 + 多实例原生播放器 |
| 同步回放时间轴 | 统一时间轴控件 + 多流 seek 同步 |
| PTZ/预设/巡逻 | `PTZ` API + 手势（拖拽/双指缩放） |
| 双向语音 | `AudioStream` API + 原生录音/播放 |
| 录像检索/下载 | `Recording` API + 文件下载/锁定 |
| 快照 | `GetSnapshot` + 本地相册保存 |
| 通知 | 注册 token 到 `Notification` API + 本地 APNs/FCM |
| 首页模式地理围栏 | `geolocator` + 地图选点 + SS 首页模式 API |
| 密码锁/Face ID | `local_auth` + `flutter_secure_storage` |
| AirPlay（iOS） | 原生 `AVPlayer` AirPlay 路由 |
| PiP（Android） | `PiP` 原生通道 |
| 硬件解码 | 原生播放器硬解（VLC/Exo/AVPlayer 默认开启） |
| 许可证管理 | `License` API（若公开，否则管理类页占位） |

---

## 8. 关键技术挑战与对策

| 挑战 | 影响 | 对策 |
|------|------|------|
| **H.264/H.265 低延迟直播** | 高 | `flutter_vlc_player` 或自建 AVPlayer/ExoPlayer Platform View；优先 RTSP over TCP |
| **双向语音** | 中 | 原生 AudioEngine + `AudioStream` 上行；注意 iOS 麦克风权限与回声消除 |
| **iOS AirPlay / Android PiP** | 中 | 原生通道实现，不在 Flutter 层强求 |
| **推送（事件触发）** | 高 | 必须走 Synology 官方推送服务注册；本地推送仅作补充，需向用户说明边界 |
| **Smart Timeline 语义** | 中 | 客户端实现时间轴缩放 + 服务端事件密度叠加，必要时实测 `entry.cgi` |
| **2FA / OTP** | 中 | 登录流程增加二次校验 UI 与 API 分支 |
| **多画面性能（6 路同播）** | 高 | 按需解码、离屏降码率、可见即播；硬件解码 |
| **证书信任** | 低 | 首次连接手动信任并持久化到受信列表 |

---

## 9. 开发路线图与里程碑

### Phase 0 — 仓库与骨架（本次已启动）
- GitHub 仓库、README、目录约定、CI 占位、UI 设计稿。

### Phase 1 — iOS MVP（≈6–8 周）
- 登录/发现/HTTPS、相机列表、多画面直播（MJPEG 起步→RTSP 硬解）、单画面 PTZ + 快照 + 手动录像、录像/快照浏览与下载、基础通知。
- **里程碑**：能连真实 NAS 看 4 路直播 + 回放。

### Phase 2 — iOS 全功能（≈3 个月累计）
- 同步回放时间轴、双向语音、首页模式地理围栏、密码锁/Face ID、AirPlay、设置全量、许可证、Smart Timeline。

### Phase 3 — Android 复用（≈4–6 周）
- 复用 90% 业务/UI 代码；补齐 PiP、ExoPlayer、FCM、权限模型差异；出 AAB。

### Phase 4 — 打磨与发布
- 性能压测（6–9 路）、国际化（对齐官方多语言）、App Store / Play 上架。

---

## 10. 工作量估算（单名资深 Flutter 工程师视角）

| 阶段 | 估算 | 关键依赖 |
|------|------|---------|
| Phase 0 | 3–5 天 | 设计稿、架构落地 |
| Phase 1 | 6–8 周 | 视频链路打通（最大不确定项） |
| Phase 2 | 8–10 周 | 原生通道、推送联调 |
| Phase 3 | 4–6 周 | 平台差异 |
| 合计 | **≈6–8 人月** | 需真实 NAS 环境持续验证 |

---

## 11. 风险与合规

- **API 稳定性**：官方 Web API 版本随 SS 升级变化，需做版本协商与降级。
- **法律**：仅用公开 API，不逆向私有协议；App 名称/图标须规避 Synology 商标侵权（"DS Cam" 为注册商标，重开作品应独立品牌）。
- **推送边界**：无法完全自建服务端事件推送，需依赖官方推送服务或自建中转（需用户自有服务器）。
- **测试环境**：必须有真实 Surveillance Station + 多品牌相机，方能验证 codec/PTZ 兼容性。

---

## 12. 结论与下一步建议

1. **立项可行**，技术路线明确：Flutter + 官方 SS Web API + 原生视频通道。
2. **优先打通视频链路**（Phase 1 的硬骨头），它决定整体成败与时间线。
3. **本阶段交付**：本报告 + UI 设计稿（见 `/ui`）+ GitHub 仓库骨架。
4. **下一步**：确认品牌名与仓库名 → 我据此初始化仓库并推送 → 进入 Phase 1 工程搭建（网络层 + 登录 + 相机列表 + 直播骨架）。

---
*本评估基于 Synology 公开文档（Surveillance Station Web API、DS Cam 规格与知识库）整理，具体 API 版本与字段以目标 NAS 实际返回的 `SYNO.API.Info` 为准。*
