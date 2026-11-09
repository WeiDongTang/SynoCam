// 全局应用状态（Provider + ChangeNotifier）。
// 真实项目可替换为 Riverpod / Bloc；此处保持轻量，聚焦链路可运行。
import 'package:flutter/foundation.dart';

import '../core/config/feature_flags.dart';
import '../core/network/syno_api.dart';
import '../core/network/syno_client.dart';
import '../core/storage/secure_store.dart';
import '../data/models/camera.dart';
import '../data/models/media.dart';
import '../data/models/syno_session.dart';
import '../data/repositories/auth_repository.dart';
import '../data/repositories/camera_repository.dart';
import '../data/repositories/media_repository.dart';

enum LoadState { idle, loading, ready, error }

class AppState extends ChangeNotifier {
  late final SynoClient _client = SynoClient();
  late final SecureStore _store = InMemorySecureStore();
  late final AuthRepository _auth = AuthRepository(_client, _store);
  late final CameraRepository _cameras = CameraRepository(_client);
  late final MediaRepository _media = MediaRepository(_client);

  final FeatureFlags flags = FeatureFlags();

  bool _bootstrapped = false;
  bool get bootstrapped => _bootstrapped;

  // ── 会话 ──
  SynoSession? _session;
  SynoSession? get session => _session;
  bool get isLoggedIn => _session != null;

  // ── 摄像机 ──
  List<Camera> _camerasList = <Camera>[];
  List<Camera> get cameras => _camerasList;
  LoadState _cameraState = LoadState.idle;
  LoadState get cameraState => _cameraState;
  String? _error;
  String? get error => _error;

  // ── UI 状态（对齐原型）──
  int _gridCount = 4;
  int get gridCount => _gridCount;
  String _cameraQuery = '';
  String get cameraQuery => _cameraQuery;
  String _cameraFilter = 'all'; // all / on / off
  String get cameraFilter => _cameraFilter;
  bool _cameraGridView = true;
  bool get cameraGridView => _cameraGridView;

  List<Recording> _recordings = <Recording>[];
  List<Recording> get recordings => _recordings;
  List<SurveillanceEvent> _events = <SurveillanceEvent>[];
  List<SurveillanceEvent> get events => _events;

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

  // ── 生命周期 ──
  Future<void> bootstrap() async {
    _session = await _auth.restore();
    if (_session != null) await refreshCameras();
    _bootstrapped = true;
    notifyListeners();
  }

  Future<void> login({
    required String host,
    required String account,
    required String password,
    bool https = false,
    int? port,
    String? otpCode,
    bool remember = true,
  }) async {
    _error = null;
    _session = await _auth.login(
      host: host,
      account: account,
      password: password,
      https: https,
      port: port,
      otpCode: otpCode,
      remember: remember,
    );
    await refreshCameras();
    notifyListeners();
  }

  Future<void> logout() async {
    await _auth.logout();
    _session = null;
    _camerasList = <Camera>[];
    _recordings = <Recording>[];
    _events = <SurveillanceEvent>[];
    notifyListeners();
  }

  // ── 数据刷新 ──
  Future<void> refreshCameras() async {
    _cameraState = LoadState.loading;
    _error = null;
    notifyListeners();
    try {
      _camerasList = await _cameras.list();
      _cameraState = LoadState.ready;
    } on SynoException catch (e) {
      _error = e.message;
      _cameraState = LoadState.error;
      if (e.needsReLogin) _session = null;
    } catch (e) {
      _error = '$e';
      _cameraState = LoadState.error;
    }
    notifyListeners();
  }

  Future<void> refreshMedia() async {
    try {
      _recordings = await _media.recordings();
      _events = await _media.events();
    } on SynoException catch (_) {
      // 媒体列表失败不阻断主界面。
    }
    notifyListeners();
  }

  // ── 摄像机操作 ──
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

  String snapshotUrl(Camera c) => _cameras.snapshotUrl(c.id);
  String liveStreamUrl(Camera c) => _cameras.liveStreamUrl(c);

  // ── PTZ 门面（供单画面页调用）──
  Future<void> ptzMove(int cameraId, String direction) =>
      _cameras.ptzMove(cameraId, direction);

  Future<void> goPreset(int cameraId, int presetId) =>
      _cameras.goPreset(cameraId, presetId);

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
