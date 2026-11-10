#!/usr/bin/env python3
"""把 App 图标与系统权限配置注入 flutter create 动态生成的原生壳。

本仓库的 ios/ 与 android/ 目录只保留 .gitkeep —— CI 用
`flutter create --platforms=ios|android` 动态生成原生工程，因此所有原生侧的
自定义（图标、Info.plist 权限键、AppDelegate、AndroidManifest 权限、MainActivity）
必须在 create 之后、build 之前由本脚本注入，否则会被模板覆盖。

用法（CI 的 working-directory 为 synocam/）：
    python3 scripts/apply_native_config.py --platform ios
    python3 scripts/apply_native_config.py --platform android

--root 可指向一份模拟的 flutter create 产物目录，便于本地验证注入结果。
脚本只用 Python 标准库，不依赖 Pillow / Xcode / Android SDK。
"""
from __future__ import annotations

import argparse
import plistlib
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_ROOT = HERE.parent
NATIVE = HERE / "native"

IOS_ICON_DIR = NATIVE / "ios_appicon"
ANDROID_ICON_DIR = NATIVE / "android_launcher"

# ── iOS Info.plist 需要补齐的权限与用途说明 ──────────────────────────────
IOS_PLIST_KEYS = {
    # 应用显示名称：按要求改回之前的英文名称。
    "CFBundleDisplayName": "SynoCam",
    # iOS 13+ 访问局域网设备时的用途说明（自有 NAS 多为局域网 / DDNS 回环）。
    "NSLocalNetworkUsageDescription":
        "用于发现并连接局域网内的群晖 NAS 与 Surveillance Station 摄像头。",
    # 保存监控快照到系统相册（写入权限，比完整读取权限更克制）。
    "NSPhotoLibraryAddUsageDescription":
        "用于将监控快照与录像片段保存到系统相册。",
    # 后台刷新 Surveillance Station 事件 + 远程通知能力声明。
    "UIBackgroundModes": ["fetch", "remote-notification"],
    # 明确声明不使用非豁免加密，避免每次提审重复填写出口合规问卷。
    "ITSAppUsesNonExemptEncryption": False,
}
# 允许局域网明文 HTTP（自签 HTTPS 由 App 内「信任自签名证书」在代码层处理，
# 这里不开放 NSAllowsArbitraryLoads，保持公网 ATS 安全策略）。
IOS_ATS = {"NSAllowsLocalNetworking": True}

# ── Android 需要声明的权限 ──────────────────────────────────────────────
ANDROID_PERMISSIONS = [
    ('android.permission.INTERNET', None),
    ('android.permission.ACCESS_NETWORK_STATE', None),
    ('android.permission.POST_NOTIFICATIONS', None),
    ('android.permission.VIBRATE', None),
    ('android.permission.WAKE_LOCK', None),
    ('android.permission.WRITE_EXTERNAL_STORAGE', '28'),
]

# ── iOS AppDelegate：请求通知授权 + MethodChannel 供 Dart 查询/请求权限 ──
APP_DELEGATE_SWIFT = '''import Flutter
import UIKit
import UserNotifications
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  private static let channelName = "com.synocam/permissions"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    // 录像 MP4 音轨 / 实时音频流需要能被听见：默认 AVAudioSession 为
    // soloAmbient，iPhone 侧边「静音键」打开时会被系统静掉。设为 playback
    // 分类后，静音键不再影响 App 内的视频与音频播放。
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback, options: [])
      try session.setActive(true)
    } catch {
      // 音频会话配置失败不应阻断启动；画面仍可正常播放。
    }

    // 首次启动请求通知权限：Surveillance Station 事件提醒（提醒 / 角标 / 声音）。
    // 重复调用是幂等的；用户拒绝后可在「设置 → 系统权限 → 打开系统设置」里修改。
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .badge, .sound]
    ) { _, _ in }

    // 与 Dart 侧 SystemPermissions 对应的真实权限通道。
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: AppDelegate.channelName,
        binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "notificationStatus":
          UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
              switch settings.authorizationStatus {
              case .authorized, .provisional:
                result("granted")
              case .denied:
                result("denied")
              case .notDetermined:
                result("notDetermined")
              @unknown default:
                result("unknown")
              }
            }
          }
        case "requestNotifications":
          UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
          ) { granted, _ in
            DispatchQueue.main.async { result(granted ? "granted" : "denied") }
          }
        case "openSettings":
          guard let url = URL(string: UIApplication.openSettingsURLString),
                UIApplication.shared.canOpenURL(url) else {
            result("unavailable")
            return
          }
          UIApplication.shared.open(url, options: [:]) { _ in result("ok") }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return launched
  }
}
'''

# ── Android MainActivity：POST_NOTIFICATIONS 运行时请求 + MethodChannel ──
def main_activity_kotlin(package: str) -> str:
    return '''package {pkg}

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {{
    companion object {{
        private const val CHANNEL = "com.synocam/permissions"
        private const val REQ_NOTIFICATIONS = 1001
    }}

    // Android 13 以下不需要运行时通知授权；13+ 读取真实授权状态。
    private fun notificationStatus(): String {{
        if (Build.VERSION.SDK_INT < 33) return "granted"
        return if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
            == PackageManager.PERMISSION_GRANTED) "granted" else "denied"
    }}

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {{
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler {{ call, result ->
                when (call.method) {{
                    "notificationStatus" -> result.success(notificationStatus())
                    "requestNotifications" -> {{
                        if (Build.VERSION.SDK_INT >= 33 &&
                            notificationStatus() != "granted") {{
                            requestPermissions(
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                REQ_NOTIFICATIONS)
                        }}
                        result.success(notificationStatus())
                    }}
                    "openSettings" -> {{
                        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                        intent.data = Uri.parse("package:$packageName")
                        startActivity(intent)
                        result.success("ok")
                    }}
                    else -> result.notImplemented()
                }}
            }}
    }}

    override fun onCreate(savedInstanceState: Bundle?) {{
        super.onCreate(savedInstanceState)
        // 首次启动向系统请求通知权限（Android 13+）；低于 13 无需请求。
        if (Build.VERSION.SDK_INT >= 33 && notificationStatus() != "granted") {{
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQ_NOTIFICATIONS)
        }}
    }}
}}
'''.format(pkg=package)


def log(msg: str) -> None:
    print("[native] " + msg, flush=True)


def die(msg: str) -> None:
    print("[native][ERROR] " + msg, file=sys.stderr, flush=True)
    sys.exit(1)


def apply_ios(root: Path) -> None:
    icon_dir = root / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    if not icon_dir.is_dir():
        die("未找到 %s —— 请先运行 flutter create --platforms=ios" % icon_dir)
    icons = sorted(IOS_ICON_DIR.glob("*.png"))
    if not icons:
        die("图标资源目录为空：%s" % IOS_ICON_DIR)
    for src in icons:
        shutil.copy2(src, icon_dir / src.name)
    contents = IOS_ICON_DIR / "Contents.json"
    if contents.is_file():
        shutil.copy2(contents, icon_dir / "Contents.json")
    log("iOS AppIcon 已注入 %d 个尺寸 + Contents.json -> %s" %
        (len(icons), icon_dir.relative_to(root)))

    plist_path = root / "ios" / "Runner" / "Info.plist"
    if not plist_path.is_file():
        die("未找到 %s" % plist_path)
    with plist_path.open("rb") as f:
        info = plistlib.load(f)
    for key, value in IOS_PLIST_KEYS.items():
        info[key] = value
    ats = info.get("NSAppTransportSecurity")
    if isinstance(ats, dict):
        ats.update(IOS_ATS)
    else:
        ats = dict(IOS_ATS)
    info["NSAppTransportSecurity"] = ats
    with plist_path.open("wb") as f:
        plistlib.dump(info, f)
    log("iOS Info.plist 已写入 %d 个权限/用途键：%s" %
        (len(IOS_PLIST_KEYS) + 1, ", ".join(list(IOS_PLIST_KEYS) + ["NSAppTransportSecurity"])))

    delegate = root / "ios" / "Runner" / "AppDelegate.swift"
    delegate.write_text(APP_DELEGATE_SWIFT, encoding="utf-8")
    log("iOS AppDelegate.swift 已注入通知授权与权限通道 -> %s" %
        delegate.relative_to(root))


def apply_android(root: Path) -> None:
    res = root / "android" / "app" / "src" / "main" / "res"
    if not res.is_dir():
        die("未找到 %s —— 请先运行 flutter create --platforms=android" % res)
    copied = 0
    for density in sorted(ANDROID_ICON_DIR.iterdir()):
        if not density.is_dir():
            continue
        src = density / "ic_launcher.png"
        if not src.is_file():
            continue
        dst_dir = res / density.name
        dst_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst_dir / "ic_launcher.png")
        copied += 1
    if copied == 0:
        die("Android 图标资源为空：%s" % ANDROID_ICON_DIR)
    log("Android ic_launcher.png 已注入 %d 档密度 -> %s" %
        (copied, res.relative_to(root)))

    manifest = root / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
    if not manifest.is_file():
        die("未找到 %s" % manifest)
    text = manifest.read_text(encoding="utf-8")
    # 与 iOS 一致：主屏幕/应用列表里显示英文名称 SynoCam。
    text = re.sub(r'android:label="[^"]*"',
                  'android:label="SynoCam"', text, count=1)
    additions = []
    for name, max_sdk in ANDROID_PERMISSIONS:
        if name in text:
            continue
        attr = (' android:maxSdkVersion="%s"' % max_sdk) if max_sdk else ""
        additions.append('    <uses-permission android:name="%s"%s/>' % (name, attr))
    m = re.search(r"<manifest\b[^>]*>", text)
    if not m:
        die("AndroidManifest.xml 缺少 <manifest> 标签")
    if additions:
        text = text[:m.end()] + "\n" + "\n".join(additions) + text[m.end():]
        manifest.write_text(text, encoding="utf-8")
    log("AndroidManifest.xml 已声明权限 %d 项（新增 %d 项）：%s" %
        (len(ANDROID_PERMISSIONS), len(additions),
         ", ".join(n.split('.')[-1] for n, _ in ANDROID_PERMISSIONS)))

    candidates = sorted(
        (root / "android" / "app" / "src" / "main").rglob("MainActivity.kt"))
    if not candidates:
        die("未找到 MainActivity.kt —— Flutter 模板结构可能已变化")
    main_activity = candidates[0]
    original = main_activity.read_text(encoding="utf-8")
    pm = re.search(r"(?m)^\s*package\s+([\w.]+)", original)
    if not pm:
        die("MainActivity.kt 缺少 package 声明")
    package = pm.group(1)
    main_activity.write_text(main_activity_kotlin(package), encoding="utf-8")
    log("MainActivity.kt 已注入 POST_NOTIFICATIONS 请求与权限通道 (package=%s) -> %s" %
        (package, main_activity.relative_to(root)))


def verify(root: Path, platform: str) -> None:
    """注入后自检：关键文件/键确实存在，缺失即让 CI 失败。"""
    problems = []
    if platform == "ios":
        icon_dir = root / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
        if not (icon_dir / "Icon-App-1024x1024@1x.png").is_file():
            problems.append("iOS 1024 图标缺失")
        plist_path = root / "ios" / "Runner" / "Info.plist"
        with plist_path.open("rb") as f:
            info = plistlib.load(f)
        for key in IOS_PLIST_KEYS:
            if key not in info:
                problems.append("Info.plist 缺少 " + key)
        if info.get("CFBundleDisplayName") != "SynoCam":
            problems.append("CFBundleDisplayName 不是 SynoCam")
        if "NSAllowsLocalNetworking" not in (info.get("NSAppTransportSecurity") or {}):
            problems.append("Info.plist 缺少 NSAllowsLocalNetworking")
        delegate = (root / "ios" / "Runner" / "AppDelegate.swift").read_text(encoding="utf-8")
        for token in ["requestAuthorization", "FlutterMethodChannel",
                      "com.synocam/permissions", "AVAudioSession", ".playback"]:
            if token not in delegate:
                problems.append("AppDelegate.swift 缺少 " + token)
    else:
        res = root / "android" / "app" / "src" / "main" / "res"
        for density in ["mipmap-mdpi", "mipmap-xxxhdpi"]:
            if not (res / density / "ic_launcher.png").is_file():
                problems.append("缺少 " + density + "/ic_launcher.png")
        manifest = (root / "android" / "app" / "src" / "main" /
                    "AndroidManifest.xml").read_text(encoding="utf-8")
        for name, _ in ANDROID_PERMISSIONS:
            if name not in manifest:
                problems.append("AndroidManifest 缺少 " + name)
        if 'android:label="SynoCam"' not in manifest:
            problems.append("AndroidManifest 应用名称不是 SynoCam")
        main_activity = next(
            (root / "android" / "app" / "src" / "main").rglob("MainActivity.kt"), None)
        if main_activity is None or "POST_NOTIFICATIONS" not in main_activity.read_text(encoding="utf-8"):
            problems.append("MainActivity.kt 未注入 POST_NOTIFICATIONS")
    if problems:
        die("注入校验失败：\n  - " + "\n  - ".join(problems))
    log("注入校验通过 ✓（%s）" % platform)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", required=True, choices=["ios", "android"])
    ap.add_argument("--root", default=str(DEFAULT_ROOT),
                    help="flutter create 产物根目录（默认 synocam/）")
    args = ap.parse_args()
    root = Path(args.root).resolve()
    log("目标根目录：%s  平台：%s" % (root, args.platform))
    if args.platform == "ios":
        apply_ios(root)
    else:
        apply_android(root)
    verify(root, args.platform)


if __name__ == "__main__":
    main()
