// 系统权限通道：与 CI 注入的 AppDelegate.swift / MainActivity.kt 中的
// MethodChannel('com.synocam/permissions') 一一对应。
//
// 只用 Flutter SDK 自带的 MethodChannel，不引入 permission_handler /
// flutter_local_notifications 等第三方插件：这些插件会拉起额外的 iOS Pod，
// 在 Flutter 3.24.5 / iOS 12 部署目标下可能与 video_player 一起触发
// pod install 的 SDK 版本冲突（本工程已因此精确锁定过插件版本）。
//
// 原生侧负责：iOS 用 UNUserNotificationCenter 请求 alert/badge/sound 授权，
// Android 13+ 用 requestPermissions 请求 POST_NOTIFICATIONS；并回传真实状态。
// 这里只做 Dart 封装，绝不伪造「已授权」。
import 'package:flutter/services.dart';

enum NotificationPermission { granted, denied, notDetermined, unknown }

extension NotificationPermissionLabel on NotificationPermission {
  String get label {
    if (this == NotificationPermission.granted) return '已授权';
    if (this == NotificationPermission.denied) return '已拒绝（可在系统设置中开启）';
    if (this == NotificationPermission.notDetermined) return '尚未请求';
    return '未读取到（原生权限通道不可用）';
  }

  bool get isGranted => this == NotificationPermission.granted;
}

class SystemPermissions {
  const SystemPermissions();

  static const MethodChannel _channel =
      MethodChannel('com.synocam/permissions');

  static NotificationPermission _parse(String? raw) {
    if (raw == 'granted') return NotificationPermission.granted;
    if (raw == 'denied') return NotificationPermission.denied;
    if (raw == 'notDetermined') return NotificationPermission.notDetermined;
    return NotificationPermission.unknown;
  }

  /// 查询真实授权状态（iOS UNAuthorizationStatus / Android checkSelfPermission）。
  Future<NotificationPermission> status() async {
    try {
      return _parse(await _channel.invokeMethod<String>('notificationStatus'));
    } on MissingPluginException {
      return NotificationPermission.unknown;
    } on PlatformException {
      return NotificationPermission.unknown;
    }
  }

  /// 主动触发系统授权弹窗；已被永久拒绝时返回 denied，调用方可引导到系统设置。
  Future<NotificationPermission> request() async {
    try {
      return _parse(
          await _channel.invokeMethod<String>('requestNotifications'));
    } on MissingPluginException {
      return NotificationPermission.unknown;
    } on PlatformException {
      return NotificationPermission.unknown;
    }
  }

  /// 打开本 App 的系统设置页，让用户自行修改通知等权限。
  Future<bool> openSettings() async {
    try {
      final r = await _channel.invokeMethod<String>('openSettings');
      return r == 'ok' || r == 'granted';
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
