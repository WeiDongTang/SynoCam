// 持久化存储：会话、设备令牌与应用偏好（shared_preferences）。
//
// 安全约定：绝不把账号密码明文写入本地。重新启动时只恢复 SID + 连接信息，
// SID 过期由首个 API 调用返回 106/119 触发重新登录（这正是 DSM 的预期行为）。
// 纯 Dart 的 InMemorySecureStore 仍保留在 secure_store.dart 供无 SDK 自检使用。
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/syno_session.dart';
import 'secure_store.dart';

class PersistentSecureStore implements SecureStore {
  SharedPreferences? _prefs;

  static const String _kSession = 'auth.session';
  static const String _kAccount = 'auth.account';
  static const String _kDeviceIds = 'auth.device_ids';

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  SharedPreferences get _p {
    final p = _prefs;
    if (p == null) {
      throw StateError('PersistentSecureStore 尚未 init()');
    }
    return p;
  }

  @override
  Future<void> saveSession(SynoSession session) async {
    await init();
    await _p.setString(_kSession, jsonEncode(session.toJson()));
    await _p.setString(_kAccount, session.account);
  }

  @override
  Future<SynoSession?> readSession() async {
    await init();
    final raw = _p.getString(_kSession);
    if (raw == null || raw.isEmpty) return null;
    try {
      return SynoSession.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      await _p.remove(_kSession);
      return null;
    }
  }

  /// 只记录账号，不落盘密码。
  @override
  Future<void> saveCredentials(String account, String password) async {
    await init();
    await _p.setString(_kAccount, account);
  }

  /// 密码不持久化，始终返回 null。
  @override
  Future<Credentials?> readCredentials() async => null;

  static String _deviceKey(String host, String account) => '$host|$account';

  @override
  Future<void> saveDeviceId(String host, String account, String did) async {
    await init();
    final map = _readDeviceIds();
    map[_deviceKey(host, account)] = did;
    await _p.setString(_kDeviceIds, jsonEncode(map));
  }

  @override
  Future<String?> readDeviceId(String host, String account) async {
    await init();
    return _readDeviceIds()[_deviceKey(host, account)];
  }

  Map<String, String> _readDeviceIds() {
    final raw = _p.getString(_kDeviceIds);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      return Map<String, String>.from(
          (jsonDecode(raw) as Map).map((k, v) => MapEntry('$k', '$v')));
    } catch (_) {
      return <String, String>{};
    }
  }

  /// 会话失效时只删除保存的 SID：保留设备令牌（did 免 2FA）与上次连接信息，
  /// 避免冷启动反复读回已失效的僵尸会话。
  Future<void> clearSessionOnly() async {
    await init();
    await _p.remove(_kSession);
  }

  @override
  Future<void> clear() async {
    await init();
    await _p.remove(_kSession);
    await _p.remove(_kAccount);
    await _p.remove(_kDeviceIds);
  }
}

/// 应用偏好：证书信任、轮询间隔、已读事件、免打扰等，全部真实持久化。
class AppPreferences {
  AppPreferences(this._store);

  final PersistentSecureStore _store;

  static const String _kAllowBadCert = 'pref.allow_bad_cert';
  static const String _kPollSeconds = 'pref.poll_seconds';
  static const String _kReadEvents = 'pref.read_events';
  static const String _kDnd = 'pref.dnd';
  static const String _kHardwareDecode = 'pref.hw_decode';
  static const String _kPip = 'pref.pip';
  static const String _kSmartTimeline = 'pref.smart_timeline';
  static const String _kStreamMode = 'pref.stream_mode';
  static const String _kLastConnection = 'auth.last_connection';
  static const String _kSessionExpired = 'auth.session_expired';
  static const String _kTimeOffsetMinutes = 'pref.time_offset_minutes';

  SharedPreferences get _p => _store._p;

  bool get allowUntrustedCert => _p.getBool(_kAllowBadCert) ?? false;
  Future<void> setAllowUntrustedCert(bool v) async {
    await _store.init();
    await _p.setBool(_kAllowBadCert, v);
  }

  int get pollSeconds => _p.getInt(_kPollSeconds) ?? 2;
  Future<void> setPollSeconds(int v) async {
    await _store.init();
    await _p.setInt(_kPollSeconds, v < 1 ? 1 : (v > 10 ? 10 : v));
  }

  Set<String> get readEventIds =>
      (_p.getStringList(_kReadEvents) ?? <String>[]).toSet();

  Future<void> markEventsRead(Iterable<String> ids) async {
    await _store.init();
    final all = readEventIds..addAll(ids);
    await _p.setStringList(_kReadEvents, all.toList());
  }

  bool get dnd => _p.getBool(_kDnd) ?? false;
  Future<void> setDnd(bool v) async {
    await _store.init();
    await _p.setBool(_kDnd, v);
  }

  bool get hardwareDecode => _p.getBool(_kHardwareDecode) ?? true;
  Future<void> setHardwareDecode(bool v) async {
    await _store.init();
    await _p.setBool(_kHardwareDecode, v);
  }

  bool get pip => _p.getBool(_kPip) ?? true;
  Future<void> setPip(bool v) async {
    await _store.init();
    await _p.setBool(_kPip, v);
  }

  bool get smartTimeline => _p.getBool(_kSmartTimeline) ?? true;
  Future<void> setSmartTimeline(bool v) async {
    await _store.init();
    await _p.setBool(_kSmartTimeline, v);
  }

  /// true = 优先 MJPEG 连续流（需 NAS 返回 StmKey），失败自动降级快照轮询；
  /// false = 只用 Camera/GetSnapshot 快照轮询。
  bool get streamMode => _p.getBool(_kStreamMode) ?? true;
  Future<void> setStreamMode(bool v) async {
    await _store.init();
    await _p.setBool(_kStreamMode, v);
  }

  /// NAS 时间展示校准偏移（分钟）。只影响 UI 展示文字，不改写请求时间戳。
  int get timeOffsetMinutes => _p.getInt(_kTimeOffsetMinutes) ?? 0;
  Future<void> setTimeOffsetMinutes(int v) async {
    await _store.init();
    var minutes = v;
    if (minutes < -720) minutes = -720;
    if (minutes > 720) minutes = 720;
    await _p.setInt(_kTimeOffsetMinutes, minutes);
  }

  /// 上次连接的非敏感参数。注意：clear() 不会删除它，用户主动退出后再次
  /// 打开 App 仍会自动预填地址 / 端口 / 账号。
  LastConnection? get lastConnection {
    final raw = _p.getString(_kLastConnection);
    if (raw == null || raw.isEmpty) return null;
    try {
      final c = LastConnection.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map));
      return c.isValid ? c : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveLastConnection(LastConnection c) async {
    await _store.init();
    await _p.setString(_kLastConnection, jsonEncode(c.toJson()));
  }

  /// 会话失效标记：登录页据此显示「登录已过期，请重新输入密码」提示。
  bool get sessionExpired => _p.getBool(_kSessionExpired) ?? false;

  Future<void> setSessionExpired(bool v) async {
    await _store.init();
    await _p.setBool(_kSessionExpired, v);
  }
}
