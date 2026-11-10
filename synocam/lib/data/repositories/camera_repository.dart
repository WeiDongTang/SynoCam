// 摄像机仓储：把 SS 原始 JSON 映射为领域模型，并封装启停/改名/PTZ/流与快照。
// 所有操作都是真实 Web API 调用；App 内不支持的操作（物理添加/删除摄像头）
// 明确抛 UnimplementedError，由 UI 引导到 SS 网页端，绝不模拟成功。
import '../../core/network/syno_api.dart';
import '../../core/network/syno_client.dart';
import '../models/camera.dart';

class CameraRepository {
  CameraRepository(this._client);

  final SynoClient _client;

  Future<List<Camera>> list() async {
    final raw = await _client.listCameras();
    final cams = raw.map(Camera.fromSynoJson).toList();

    // List 未返回 StmKey 时，补调 GetLiveViewPath 拿真实流路径。
    final missing = cams.where((c) => !c.canStream).map((c) => c.id).toList();
    if (missing.isNotEmpty) {
      try {
        final paths = await _client.getLiveViewPaths(missing);
        if (paths.isNotEmpty) {
          return cams.map((c) => _attachPath(c, paths)).toList();
        }
      } catch (_) {
        // 取流路径失败保留原值；UI 会显示「未返回直播流凭证」。
      }
    }
    return cams;
  }

  Camera _attachPath(Camera c, Map<int, String> paths) {
    final path = paths[c.id];
    if (path == null || path.isEmpty) return c;
    final key = Camera.fromSynoJson(<String, dynamic>{'StmKey': path}).stmKey;
    // livePath 本身已含 StmKey，播放时优先原样使用，故 key 可为 null。
    return c.copyWith(stmKey: key, livePath: path);
  }

  /// 真实快照字节（走 Dio 链路，带 Cookie，避免 Image.network 的 465）。
  Future<List<int>> snapshotBytes(int cameraId) =>
      _client.getSnapshot(cameraId);

  Future<String> testSnapshot(int cameraId) => _client.testSnapshot(cameraId);

  String get mediaDiagnostic => _client.mediaDiagnostic;

  String get cookieHeader => _client.cookieHeader;

  String snapshotUrl(int cameraId, {int? nonce}) =>
      _client.snapshotUrl(cameraId, nonce: nonce);

  String liveStreamUrl(Camera camera, {int? startTime, int? endTime}) => _client
      .liveStreamUrl(camera: camera, startTime: startTime, endTime: endTime);

  String rtspUrl(Camera camera) => _client.rtspUrl(camera.id);

  String webUiUrl() => _client.webUiUrl();

  Future<void> setEnabled(int cameraId, bool enabled) =>
      _client.setCameraEnabled(<int>[cameraId], enabled);

  Future<void> rename(int cameraId, String name) =>
      _client.saveCamera(cameraId, name: name);

  Future<void> updateQuality(int cameraId, String quality) =>
      _client.saveCamera(cameraId, quality: quality);

  Future<void> ptzMove(int cameraId, String direction, {int speed = 3}) =>
      _client.ptz(
        SynoMethod.move,
        cameraId,
        extra: <String, String?>{
          'direction': direction,
          'speed': '$speed',
        },
      );

  Future<void> ptzZoom(int cameraId, String inOrOut) => _client.ptz(
        SynoMethod.zoom,
        cameraId,
        extra: <String, String?>{'control': inOrOut},
      );

  Future<void> goPreset(int cameraId, int presetId) => _client.ptz(
        SynoMethod.goPreset,
        cameraId,
        extra: <String, String?>{'presetId': '$presetId'},
      );

  Future<void> runPatrol(int cameraId) =>
      _client.ptz(SynoMethod.runPatrol, cameraId);

  Future<List<Map<String, dynamic>>> listPresets(int cameraId) =>
      _client.listPresets(cameraId);

  Future<Map<String, dynamic>?> licenseInfo() => _client.licenseInfo();

  Future<Map<String, dynamic>?> homeModeInfo() => _client.homeModeInfo();

  Future<void> setHomeMode(bool enabled) => _client.setHomeMode(enabled);
}
