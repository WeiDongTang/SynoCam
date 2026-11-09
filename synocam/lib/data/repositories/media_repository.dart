// 录像 / 快照 / 事件仓储。SS 的 List 返回字段因版本差异较大，这里做宽松解析；
// 未能映射的字段用安全默认值，保证 UI 不会因个别缺失字段崩溃。
import '../../core/config/app_config.dart';
import '../../core/network/syno_api.dart';
import '../../core/network/syno_client.dart';
import '../models/media.dart';

class MediaRepository {
  MediaRepository(this._client);

  final SynoClient _client;

  Future<List<Recording>> recordings({int cameraId = -1}) async {
    final data = await _client.call(
      api: SynoApi.recording,
      method: SynoMethod.list,
      params: <String, String?>{
        'cameraIds': cameraId < 0 ? '' : '$cameraId',
        'limit': '${AppConfig.recordingPageSize}',
      },
    );
    final raw = data['recordings'] ?? data['recordingsList'] ?? data['list'];
    if (raw is! List) return <Recording>[];
    return raw.whereType<Map<String, dynamic>>().map(_recording).toList();
  }

  Recording _recording(Map<String, dynamic> j) {
    final startMs = (j['startTime'] as num?)?.toInt() ?? 0;
    return Recording(
      id: '${j['id'] ?? j['recordingId'] ?? startMs}',
      cameraId: (j['cameraId'] as num?)?.toInt() ?? 0,
      cameraName: '${j['cameraName'] ?? '摄像机'}',
      startTime: DateTime.fromMillisecondsSinceEpoch(
          startMs > 1e12 ? startMs : startMs * 1000),
      durationSeconds: (j['duration'] as num?)?.toInt() ??
          (j['durationSeconds'] as num?)?.toInt() ??
          0,
      locked: j['locked'] == true || j['isLocked'] == true,
      eventType: '${j['eventType'] ?? j['reason'] ?? '连续录制'}',
    );
  }

  Future<List<SurveillanceEvent>> events() async {
    final data = await _client.call(
      api: SynoApi.event,
      method: SynoMethod.list,
      params: <String, String?>{'limit': '${AppConfig.eventPageSize}'},
    );
    final raw = data['events'] ?? data['list'];
    if (raw is! List) return <SurveillanceEvent>[];
    return raw.whereType<Map<String, dynamic>>().map(_event).toList();
  }

  SurveillanceEvent _event(Map<String, dynamic> j) {
    final ts =
        (j['timestamp'] as num?)?.toInt() ?? (j['time'] as num?)?.toInt() ?? 0;
    return SurveillanceEvent(
      id: '${j['id'] ?? j['eventId'] ?? ts}',
      title: '${j['desc'] ?? j['description'] ?? j['title'] ?? '事件'}',
      time: DateTime.fromMillisecondsSinceEpoch(ts > 1e12 ? ts : ts * 1000),
      type: '${j['type'] ?? j['eventType'] ?? 'system'}',
      read: j['read'] == true || j['isRead'] == true,
      cameraId: (j['cameraId'] as num?)?.toInt(),
    );
  }

  Future<void> setLocked(String recordingId, bool locked) async {
    await _client.call(
      api: SynoApi.recording,
      method: locked ? SynoMethod.lock : SynoMethod.unlock,
      params: <String, String?>{'id': recordingId},
    );
  }

  Future<void> deleteRecording(String recordingId) async {
    await _client.call(
      api: SynoApi.recording,
      method: SynoMethod.delete,
      params: <String, String?>{'id': recordingId},
    );
  }
}
