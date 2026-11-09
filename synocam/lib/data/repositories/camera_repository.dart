// 摄像机仓储：把 SS 原始 JSON 映射为领域模型，并封装启停/改名/PTZ/直播 URL。
import '../../core/network/syno_api.dart';
import '../../core/network/syno_client.dart';
import '../models/camera.dart';

class CameraRepository {
  CameraRepository(this._client);

  final SynoClient _client;

  Future<List<Camera>> list() async {
    final raw = await _client.listCameras();
    return raw.map(Camera.fromSynoJson).toList();
  }

  Future<List<int>> snapshot(int cameraId) => _client.getSnapshot(cameraId);

  String snapshotUrl(int cameraId) => _client.snapshotUrl(cameraId);

  String liveStreamUrl(Camera camera) => _client.liveStreamUrl(
        cameraId: camera.id,
        stmKey: camera.stmKey ?? '',
      );

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
}
