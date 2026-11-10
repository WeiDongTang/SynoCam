// 全局应用状态（Provider + ChangeNotifier）。
// 所有列表数据均来自真实 Synology Web API；加载失败保留错误码供 UI 展示，
// 绝不回退到任何静态演示数据。
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/config/feature_flags.dart';
import '../core/network/cert_policy.dart';
import '../core/network/syno_api.dart';
import '../core/network/syno_client.dart';
import '../core/storage/persistent_store.dart';
import '../data/models/camera.dart';
import '../data/models/media.dart';
import '../data/models/syno_session.dart';
import '../data/repositories/auth_repository.dart';
import '../data/repositories/camera_repository.dart';
import '../data/repositories/media_repository.dart';

enum LoadState { idle, loading, ready, error }

class AppState extends ChangeNotifier {
  late final SynoClient _client = SynoClient();
  late final PersistentSecureStore _store = PersistentSecureStore();
  late final AppPreferences _prefs = AppPreferences(_store);
  late final AuthRepository _auth = AuthRepository(_client, _store);
  late final CameraRepository _cameras = CameraRepository(_client);
  late final MediaRepository _media = MediaRepository(_client);

  final FeatureFlags flags = FeatureFlags();

  AppState() {
    // 任何 API 链路（JSON / 快照 / 录像下载 / PTZ）识别出会话失效，
    // 都统一在此清除僵尸会话，不再让每个页面各自报一次 465。
    _client.onSessionExpired = _onClientSessionExpired;
  }

  AppPreferences get prefs => _prefs;

  bool _bootstrapped = false;
  bool get bootstrapped => _bootstrapped;

  SynoSession? _session;
  SynoSession? get session => _session;
  bool get isLoggedIn => _session != null;

  bool _sessionExpired = false;
  bool get sessionExpired => _sessionExpired;

  /// 上次连接参数（登录页预填用，不含密码）。
  LastConnection? get lastConnection => _prefs.lastConnection;

  /// SYNO.API.Info 的真实探测结果（失败时含原因），供设置页展示。
  String get discoverDiagnostic => _client.discoverDiagnostic;

  /// 统一的会话失效处理：清内存中的僵尸会话 + 打标记 + 通知 UI 回登录页。
  /// 不请求 NAS、不删持久化的设备令牌与连接信息，保证重登可免验证码并预填。
  void _onClientSessionExpired() {
    if (_session == null) return;
    _sessionExpired = true;
    _session = null;
    _camerasList = <Camera>[];
    _recordings = <Recording>[];
    _events = <SurveillanceEvent>[];
    _license = null;
    _cameraState = LoadState.idle;
    _mediaState = LoadState.idle;
    _client.clearSession();
    unawaited(_prefs.setSessionExpired(true));
    // 删掉持久化的废弃 SID；保留 did 与上次连接信息。
    unawaited(_store.clearSessionOnly());
    // 避免在 build 期间同步触发 setState / 页面切换断言。
    unawaited(Future.microtask(notifyListeners));
  }

  /// 供 MJPEG 流客户端 / 子页面主动上报会话失效（幂等）。
  void reportSessionExpired() => _onClientSessionExpired();

  bool _handleReLogin(SynoException e) {
    if (!e.needsReLogin) return false;
    _onClientSessionExpired();
    return true;
  }

  /// NAS 实际支持的 API 能力（SYNO.API.Info 结果），供诊断页展示。
  Map<String, SynoApiInfoEntry> get apiInfo => _client.apiInfo;

  // ── 摄像机 ──
  List<Camera> _camerasList = <Camera>[];
  List<Camera> get cameras => _camerasList;
  LoadState _cameraState = LoadState.idle;
  LoadState get cameraState => _cameraState;
  String? _cameraError;
  String? get cameraError => _cameraError;

  // ── 录像 / 通知 ──
  List<Recording> _recordings = <Recording>[];
  List<Recording> get recordings => _recordings;
  List<SurveillanceEvent> _events = <SurveillanceEvent>[];
  List<SurveillanceEvent> get events => _events;
  LoadState _mediaState = LoadState.idle;
  LoadState get mediaState => _mediaState;
  String? _mediaError;
  String? get mediaError => _mediaError;
  int _eventTotal = 0;
  int get eventTotal => _eventTotal;
  Set<String> _readEventIds = <String>{};
  Set<String> get readEventIds => _readEventIds;

  // ── NAS 能力信息 ──
  Map<String, dynamic>? _license;
  Map<String, dynamic>? get license => _license;
  bool _homeMode = false;
  bool get homeMode => _homeMode;
  bool _homeModeSupported = false;
  bool get homeModeSupported => _homeModeSupported;

  // ── UI 状态（真实交互状态，非演示数据）──
  int _gridCount = 4;
  int get gridCount => _gridCount;
  String _cameraQuery = '';
  String get cameraQuery => _cameraQuery;
  String _cameraFilter = 'all';
  String get cameraFilter => _cameraFilter;
  bool _cameraGridView = true;
  bool get cameraGridView => _cameraGridView;

  List<Camera> get filteredCameras {
    final q = _cameraQuery.trim().toLowerCase();
    return _camerasList.where((c) {
      final matchFilter = _cameraFilter == 'all' ||
          (_cameraFilter == 'on' ? c.isOnline : !c.isOnline);
      final matchQuery = q.isEmpty ||
          c.name.toLowerCase().contains(q) ||
          c.ip.contains(q) ||
          c.model.toLowerCase().contains(q);
      return matchFilter && matchQuery;
    }).toList();
  }

  Map<int, String> get cameraNames =>
      <int, String>{for (final c in _camerasList) c.id: c.name};

  // ── 生命周期 ──
  Future<void> bootstrap() async {
    await _store.init();
    applyCertificatePolicy(_prefs.allowUntrustedCert);
    _readEventIds = _prefs.readEventIds;
    _sessionExpired = _prefs.sessionExpired;
    // 上次已判定会话失效：直接回登录页（带预填与过期提示），不再恢复僵尸
    // SID、也不依赖 NAS 当前是否可达，避免 NAS 离线时卡在报错页面。
    _session = _sessionExpired ? null : await _auth.restore();
    if (_session != null) {
      // 冷启动探针：恢复的 SID 是否仍被 NAS 接受。外网 / DDNS 场景下 DSM
      // 常以 HTTP 465 + 登录页 HTML 拒绝过期会话，必须在这里就识别出来，
      // 否则会带着僵尸会话逐页刷出 465。网络 / 证书类错误保留会话，
      // 由各页面显示真实诊断（不误清登录态）。
      try {
        await _client.validateSession();
      } on SynoException catch (e) {
        if (e.needsReLogin) _onClientSessionExpired();
      } catch (_) {
        // 保留会话，交由页面显示真实网络错误。
      }
      if (_session != null) {
        if (_sessionExpired) {
          _sessionExpired = false;
          await _prefs.setSessionExpired(false);
        }
        await _client.discoverApis();
      }
      // 每一步后都检查：能力发现或刷新途中若再次判定会话失效，
      // 立即短路，避免后续调用带着已清空的会话报错。
      if (_session != null) await refreshCameras();
      if (_session != null) await refreshMedia();
      if (_session != null) await refreshNasInfo();
    }
    _bootstrapped = true;
    notifyListeners();
  }

  Future<String?> deviceId(String host, String account) =>
      _auth.deviceId(host, account);

  Future<void> login({
    required String host,
    required String account,
    required String password,
    bool https = false,
    int? port,
    String? otpCode,
    bool enableDeviceToken = false,
    String? deviceName,
    bool remember = true,
  }) async {
    _session = await _auth.login(
      host: host,
      account: account,
      password: password,
      https: https,
      port: port,
      otpCode: otpCode,
      enableDeviceToken: enableDeviceToken,
      deviceName: deviceName,
      remember: remember,
    );
    _sessionExpired = false;
    await _prefs.setSessionExpired(false);
    // 保存非敏感连接参数，供会话失效后回到登录页自动预填（绝不存密码）。
    final previous = _prefs.lastConnection;
    await _prefs.saveLastConnection(LastConnection(
      host: _session!.host,
      account: account,
      https: https,
      port: port ?? (https ? SynoEndpoints.httpsPort : SynoEndpoints.httpPort),
      twoFactor: (otpCode != null && otpCode.isNotEmpty) ||
          enableDeviceToken ||
          (previous?.twoFactor ?? false),
      trustDevice: enableDeviceToken || (previous?.trustDevice ?? false),
    ));
    await refreshCameras();
    await refreshMedia();
    await refreshNasInfo();
    notifyListeners();
  }

  Future<void> logout() async {
    await _auth.logout();
    _sessionExpired = false;
    await _prefs.setSessionExpired(false);
    _session = null;
    _camerasList = <Camera>[];
    _recordings = <Recording>[];
    _events = <SurveillanceEvent>[];
    _license = null;
    _cameraState = LoadState.idle;
    _mediaState = LoadState.idle;
    notifyListeners();
  }

  // ── 真实数据刷新 ──
  Future<void> refreshAll() async {
    await refreshCameras();
    await refreshMedia();
    await refreshNasInfo();
  }

  Future<void> refreshCameras() async {
    _cameraState = LoadState.loading;
    _cameraError = null;
    notifyListeners();
    try {
      _camerasList = await _cameras.list();
      _cameraState = LoadState.ready;
    } on SynoException catch (e) {
      _cameraError = e.diagnostic;
      _cameraState = LoadState.error;
      _handleReLogin(e);
    } catch (e) {
      _cameraError = '$e';
      _cameraState = LoadState.error;
    }
    notifyListeners();
  }

  Future<void> refreshMedia() async {
    _mediaState = LoadState.loading;
    _mediaError = null;
    notifyListeners();
    try {
      _recordings = await _media.recordings(cameraNames: cameraNames);
      _events = _recordings.map(SurveillanceEvent.fromRecording).toList();
      _eventTotal = _recordings.length;
      _mediaState = LoadState.ready;
    } on SynoException catch (e) {
      _mediaError = e.diagnostic;
      _mediaState = LoadState.error;
      _handleReLogin(e);
    } catch (e) {
      _mediaError = '$e';
      _mediaState = LoadState.error;
    }
    notifyListeners();
  }

  Future<void> refreshNasInfo() async {
    _license = await _cameras.licenseInfo();
    final hm = await _cameras.homeModeInfo();
    _homeModeSupported = hm != null;
    if (hm != null) {
      _homeMode = hm['on'] == true ||
          hm['enabled'] == true ||
          hm['homeMode'] == true ||
          hm['status'] == 1;
    }
    notifyListeners();
  }

  Future<void> setHomeMode(bool enabled) async {
    await _cameras.setHomeMode(enabled);
    _homeMode = enabled;
    notifyListeners();
  }

  // ── 录像操作（真实 API）──
  Future<void> setRecordingLocked(Recording r, bool locked) async {
    await _media.setLocked(r.id, locked);
    _recordings = _recordings
        .map((x) => x.id == r.id
            ? Recording(
                id: x.id,
                cameraId: x.cameraId,
                cameraName: x.cameraName,
                startTime: x.startTime,
                durationSeconds: x.durationSeconds,
                locked: locked,
                recording: x.recording,
                eventType: x.eventType,
                codec: x.codec,
              )
            : x)
        .toList();
    _events = _recordings.map(SurveillanceEvent.fromRecording).toList();
    notifyListeners();
  }

  Future<void> deleteRecording(Recording r) async {
    await _media.deleteRecording(r.id);
    _recordings = _recordings.where((x) => x.id != r.id).toList();
    _events = _recordings.map(SurveillanceEvent.fromRecording).toList();
    notifyListeners();
  }

  String recordingDownloadUrl(Recording r) => _media.downloadUrl(r.id);

  Future<void> markAllEventsRead() async {
    await _prefs.markEventsRead(_events.map((e) => e.id));
    _readEventIds = _prefs.readEventIds;
    notifyListeners();
  }

  Future<void> markEventRead(String id) async {
    await _prefs.markEventsRead(<String>[id]);
    _readEventIds = _prefs.readEventIds;
    notifyListeners();
  }

  // ── 摄像机操作（真实 API）──
  Future<void> toggleCamera(Camera c, bool enabled) async {
    await _cameras.setEnabled(c.id, enabled);
    _camerasList = _camerasList
        .map((x) => x.id == c.id ? x.copyWith(enabled: enabled) : x)
        .toList();
    notifyListeners();
  }

  Future<void> saveCamera(Camera c, {String? name, String? quality}) async {
    if (name != null && name != c.name) await _cameras.rename(c.id, name);
    if (quality != null && quality != c.quality) {
      await _cameras.updateQuality(c.id, quality);
    }
    _camerasList = _camerasList
        .map((x) => x.id == c.id
            ? x.copyWith(name: name ?? x.name, quality: quality ?? x.quality)
            : x)
        .toList();
    notifyListeners();
  }

  String snapshotUrl(Camera c, {int? nonce}) =>
      _cameras.snapshotUrl(c.id, nonce: nonce);

  /// 真实快照字节：走 Dio + Cookie 链路，替代会返回 465 的 Image.network。
  Future<List<int>> snapshotBytes(Camera c) => _cameras.snapshotBytes(c.id);
  Future<List<int>> takeSnapshot(Camera c) => _cameras.snapshotBytes(c.id);

  String liveStreamUrl(Camera c, {int? startTime, int? endTime}) =>
      _cameras.liveStreamUrl(c, startTime: startTime, endTime: endTime);
  String rtspUrl(Camera c) => _cameras.rtspUrl(c);
  String webUiUrl() => _cameras.webUiUrl();

  /// 供 MJPEG 流客户端使用的会话 Cookie，以及连接诊断信息。
  String get cookieHeader => _cameras.cookieHeader;
  String get mediaDiagnostic => _cameras.mediaDiagnostic;
  Future<String> testSnapshot(Camera c) => _cameras.testSnapshot(c.id);

  /// 下载真实录像片段，供 App 内播放器读取（默认不再跳浏览器）。
  Future<RecordingFile> downloadRecording(Recording r) =>
      _media.downloadRecording(r);

  // ── PTZ 门面 ──
  Future<void> ptzMove(int cameraId, String direction) =>
      _cameras.ptzMove(cameraId, direction);
  Future<void> ptzZoom(int cameraId, String inOrOut) =>
      _cameras.ptzZoom(cameraId, inOrOut);
  Future<void> goPreset(int cameraId, int presetId) =>
      _cameras.goPreset(cameraId, presetId);
  Future<void> runPatrol(int cameraId) => _cameras.runPatrol(cameraId);
  Future<List<Map<String, dynamic>>> listPresets(int cameraId) =>
      _cameras.listPresets(cameraId);

  // ── 设置（真实持久化 + 生效）──
  Future<void> setAllowUntrustedCert(bool v) async {
    await _prefs.setAllowUntrustedCert(v);
    applyCertificatePolicy(v);
    notifyListeners();
    if (_session != null) await refreshCameras();
  }

  Future<void> setPollSeconds(int v) async {
    await _prefs.setPollSeconds(v);
    notifyListeners();
  }

  /// 切换「MJPEG 连续流 / 快照轮询」：所有预览组件会立即按新配置重启。
  Future<void> setStreamMode(bool v) async {
    await _prefs.setStreamMode(v);
    notifyListeners();
  }

  Future<void> setDnd(bool v) async {
    await _prefs.setDnd(v);
    notifyListeners();
  }

  Future<void> setHardwareDecode(bool v) async {
    await _prefs.setHardwareDecode(v);
    notifyListeners();
  }

  Future<void> setPip(bool v) async {
    await _prefs.setPip(v);
    notifyListeners();
  }

  Future<void> setSmartTimeline(bool v) async {
    await _prefs.setSmartTimeline(v);
    notifyListeners();
  }

  // ── UI setters ──
  void setGridCount(int n) {
    _gridCount = n;
    notifyListeners();
  }

  void setCameraQuery(String q) {
    _cameraQuery = q;
    notifyListeners();
  }

  void setCameraFilter(String f) {
    _cameraFilter = f;
    notifyListeners();
  }

  void toggleCameraView() {
    _cameraGridView = !_cameraGridView;
    notifyListeners();
  }
}
