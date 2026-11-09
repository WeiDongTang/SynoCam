# SynoCam · UI 设计稿说明（定稿 A）

> **定稿：方案 A · Aurora 浅色原生**（第 3 轮三选一后确定）
> 定稿原型：[`ui/index.html`](../ui/index.html)（可交互，浏览器直接打开）
> 历史方案对比：[`ui/compare.html`](../ui/compare.html)（B/C 归档）
> 画面素材：`ui/assets/cam1-3.jpg`（真实感监控视角，已去水印、统一冷调）
> 设计语境：[`.impeccable.md`](../.impeccable.md)

---

## 0. 本轮整改（相对第 3 轮方案 A）

用户选定 A 后指出两点，均已修复：

1. **图标不统一 / 与 iOS 风格有出入**：原设置页混用 emoji（🔒 ◉ ▣ ⚡ …）与 Unicode 字符，且各页图标线宽、圆角、填充不一致。
   → 建立**全站唯一 SVG symbol 图标库**（SF Symbols 风格），逐页替换，含标签栏、导航、快捷操作、PTZ 控制盘、时间轴控制、设置分组、事件类型、摄像机管理、表单、状态徽标。
2. **功能缺失（违反"不弱于官方"基线）**：第 3 轮为三稿公平对比把功能骨架缩水，砍掉了官方 DS Cam 的「摄像机」管理页，导致**无法编辑摄像头信息、无法添加摄像头**。
   → 信息架构对齐官方 **5 主 tab + 二级页面**，补齐摄像机管理 / 添加 / 编辑全部能力。

附带修复：hash 深链导致的默认焦点黑框、摄像机图注残留符号、流质量下拉档位映射。

### 0.1 Phase 1 追加修复：图标「显示不全 / 错位」根因

用户进入实施阶段时反馈「App 里面图标显示并不全、错位了」。定位到**技术根因**：上述 57 个 `<symbol>` 定义时**缺少 `viewBox="0 0 24 24"`**——图标路径按 24×24 网格绘制，但 symbol 未声明 viewBox，`<use>` 引用时内容不随容器缩放，直接以 24 用户单位画进 20px/16px 的 `<svg class="ic">`，导致**超出部分被裁切（显示不全）、不同尺寸下大小参差（错位）**。

修复：为全部 57 个 `<symbol>` 补齐 `viewBox="0 0 24 24"`，`<use>` 会按 symbol 的 viewBox 映射到 `<svg>` 视口并按 `.ic/.sm/.lg` 尺寸正确缩放。已用无头 Chromium 对 8 个页面状态逐一截图核验：图标完整、居中、尺寸一致、无裁切。

**工程层预防**（Flutter 工程）：`core/theme/app_icons.dart` 建立唯一 `IconData` 映射表、`widgets/app_icon.dart` 用 `AppIcon`/`BadgeIcon` 统一尺寸与色调，禁止页面散写 `Icons.xxx`/emoji，从架构上杜绝同类问题。详见 [`ARCHITECTURE.md`](ARCHITECTURE.md) 第 3 节。

### 0.2 追加：2FA 两步验证登录页（用户「开启二次验证后登录报错」）

原型原本是「已登录态」的 5 tab，缺少登录视图。本轮补 `p-login` 二级页（复用 `.page/.field/.group/.btn-primary` 与既有 symbol 图标），完整演示群晖 2FA 登录闭环：

- **初始态**：服务器（地址/端口/HTTPS）、账户（账号/密码）、「账号已开启两步验证」开关；
- **403 态**：只输密码点登录 → 蓝色引导横幅「该账号已开启两步验证（DSM 返回 403）…」+ 自动展开 6 位 OTP 框并聚焦；
- **404 态**：验证码错误 → 红色横幅「验证码错误或已过期（DSM 返回 404）…」，保持 OTP 框；
- **成功态**：绿色横幅 + 信任此设备说明；「信任此设备（下次免验证码）」开关对齐官方「受信连接」。

交互函数 `toggle2fa()/tryLogin()/resetLogin()`，演示验证码 `123456`。已用无头 Chromium 渲染 3 态核验：图标完整、无重叠、横幅在 OTP 框上方、登录按钮与底部说明滚动可见。全部 `<use>` 引用均有对应 `<symbol>` 且 viewBox 齐全。

**深链预览**：`index.html#v-live` / `#v-cam` / `#v-rec` / `#v-alert` / `#v-set` / `#p-single` / `#p-edit` / `#p-add` / **`#p-login`**（直达 2FA 登录演示，默认展开 403 态）；设置页「账户与服务器」也可点开。

---

## 1. 设计语言（Design System）

### 1.1 色彩
| Token | 用途 | 取值 |
|-------|------|------|
| `--bg` | 页面浅灰底 | `#EDEEF1` |
| `--card` | 分组卡片 | `#FFFFFF` |
| `--line / --line2` | 分隔线 | `rgba(18,22,30,.075 / .045)` |
| `--blue` | 主色（iOS 蓝） | `#1C6BF2` |
| `--green / --amber / --red` | 状态：在线 / 待机 / 告警 | `#1BA36A / #D98A2B / #E14B3F` |

### 1.2 字体
- 正文 / 标题：`Inter`（近似 SF Pro），iOS Large Title 29px。
- 数据 / 时间戳 / 码率 / IP：`JetBrains Mono`，右对齐。

### 1.3 形状、动效与图标
- 圆角 8 / 11 / 12 / 14 / 16px 分层；柔和阴影 `0 1px 2px + 0 8px 24px -14px`。
- 分段控制器（Segmented Control）、inset grouped list、iOS 绿色开关、搜索框。
- 动效仅服务状态变化（视图淡入、二级页 push、开关、toast），指数缓动 `cubic-bezier(.16,1,.3,1)`，无回弹。
- **图标规范（硬性）**：内联 SVG `<symbol>`，24×24 网格、`fill:none`、`stroke:currentColor`、`stroke-width:1.7`、linecap/linejoin round；`.ic` 统一 20/16/24px；**禁止 emoji 与字符图标**。

---

## 2. 信息架构（对齐官方 DS Cam）

### 2.1 五个主 Tab
| # | Tab | 能力 | 对应官方 |
|---|-----|------|---------|
| 1 | **实时** | Multi View 布局 1 / 1×2 / 2×2 / 3×3、画面点击进入单画面、系统状态 | Multi View |
| 2 | **摄像机** | 列表 / 缩略图切换、按名称/IP/状态搜索、在线筛选、启停、编辑入口、添加入口 | Cameras |
| 3 | **录像** | 录像 / 快照分段、日期/锁定/录制模式筛选、下载、锁定、预览 | Recordings / Snapshots |
| 4 | **通知** | 事件推送列表、已读/类型筛选、免打扰、推送设置 | Notifications / Home Mode 提示 |
| 5 | **设置** | 首页模式地图、密码锁/Face ID/AirPlay、硬解/悬浮/Smart Timeline、许可证/推送/受信连接/账户 | Settings |

### 2.2 二级页面（iOS push 风格，带返回栏）
| 页面 | 入口 | 能力 |
|------|------|------|
| **单画面** | 实时网格 / 摄像机行 | PTZ 控制盘、光学变焦、预置位、巡逻、双向语音、快照、静音、手动录像、0.25–5x 变速回放、关键帧、Smart Timeline、设备信息 |
| **编辑摄像机** | 摄像机行铅笔按钮 / 单画面右上编辑 / 设备信息 | 修改名称、启用/停用、流质量（4MP/2K/1080P）、编码、数字输出、录像模式、保存 / 删除 |
| **添加摄像头** | 摄像机页 + / 设置页摄像机管理 | **自动发现**（局域网 Synology 设备，型号/序列号/IP，多选批量添加）、**二维码配网**（扫码 + Wi-Fi/加密/DHCP）、**手动添加**（IP/端口/品牌/账号/HTTPS）、许可证额度提示 |

> 官方边界已如实标注：**仅 Synology 品牌摄像头可在 App 内添加**；第三方 IP 摄像头需先在 Surveillance Station 网页端配置。型号/序列号/IP 等由 SS 管理，App 内可改名称/启停/流质量/录像模式。

---

## 3. 与官方 DS Cam 的功能等价性

| 官方模块 | 本定稿覆盖 |
|---------|-----------|
| 多画面布局 / 同步回放 / 变速 / 快捷面板 | ✅ 实时 + 单画面时间轴 |
| 单画面 PTZ / 变焦 / 预设 / 巡逻 / 双向语音 / 快照 / 手动录像 | ✅ 单画面快捷操作 + PTZ 盘 |
| 摄像机列表 / 缩略图 / 启停 / 搜索 / 排序 / 基础信息 | ✅ 摄像机 tab（列表+缩略图切换、搜索、筛选、启停、信息） |
| **添加摄像头 / 编辑摄像头信息** | ✅ 二级页（本轮补齐） |
| 录像检索 / 锁定 / 下载 / 时长截取 / 快照管理 | ✅ 录像 tab（录像/快照分段 + 下载/锁定） |
| 事件通知 / 免打扰 / Do Not Disturb | ✅ 通知 tab |
| 首页模式地理围栏 | ✅ 设置 tab 地图（半径/延迟） |
| 密码锁 / Face ID / 受信连接 | ✅ 设置 tab |
| 硬件解码 / 悬浮播放器 / Smart Timeline / AirPlay | ✅ 设置 tab |
| 许可证管理 / 推送设置 / 账户 | ✅ 设置 tab |
| 登录 / QuickConnect / HTTPS / 局域网发现 | ⏳ 工程阶段接入（评估见 `EVALUATION.md`），原型以已登录态呈现 |

---

## 4. 逐页图标一致性核查结果

| 页面 | 图标来源 | 结果 |
|------|---------|------|
| 标签栏（5） | grid / camera / film / bell / gear | ✅ 统一 |
| 头部工具（搜索 / 视图切换 / 添加） | search / tiles-list / plus | ✅ 统一 |
| 实时系统状态 | server / bell | ✅ 统一 |
| 单画面快捷操作（6） | camera / mic / zoom / target / patrol / mute | ✅ 统一 |
| PTZ 控制盘 | up / down / left / right / target | ✅ 统一 |
| 时间轴控制 | skipback / play / pause / skipfwd / keyframe | ✅ 统一 |
| 事件类型 | alert / door / sparkles / cpu / server | ✅ 统一 |
| 录像动作 | download / eye | ✅ 统一 |
| 设置分组（10+） | lock / faceid / airplay / bolt / pip / timeline / license / moon / shield / camera / server | ✅ 统一 |
| 摄像机管理 / 编辑 / 添加 | pencil / power / info / qr / wifi / refresh / trash / check / plus | ✅ 统一 |
| 表单只读项 / 徽标 | chev / checkcircle | ✅ 统一 |

> 全部 8 个页面状态已用无头浏览器逐一渲染截图核验（无溢出、无重叠、无 emoji 残留）。

---

## 5. 后续设计任务（进入工程）

1. 导出设计 token 为 Flutter `ThemeData` + `ColorScheme`；SVG symbol 库转为 Flutter `IconData` 或统一图标组件。
2. 补齐登录 / QuickConnect / HTTPS 证书信任 / 局域网发现页。
3. 补 PiP（Android）、AirPlay 路由（iOS）、双向语音原生通道交互态。
4. 亮/暗双主题（当前仅浅色）；暗色保持同一图标系统与主色。
5. 首页模式编辑页、受信连接管理页、许可证增删页作为独立二级页细化。
