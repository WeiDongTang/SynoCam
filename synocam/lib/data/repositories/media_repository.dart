// 录像 / 事件仓储：全部数据来自 SYNO.SurveillanceStation.Event / Query。
// 不再有任何静态演示数据：接口失败抛异常，空结果返回空列表，由 UI 显示真实空态。
import '../../core/network/syno_client.dart';
import '../models/media.dart';

class MediaRepository {
  MediaRepository(this._client);

  final SynoClient _client;

  /// 查询真实录像片段。
  Future<List<Recording>> recordings({
    required Map<int, String> cameraNames,
    int limit = 100,
    int offset = 0,
    DateTime? from,
    DateTime? to,
    int? cameraId,
    int? locked,
    int? mode,
  }) async {
    final data = await _client.queryEvents(
      limit: limit,
      offset: offset,
      fromTime: from == null ? null : from.millisecondsSinceEpoch ~/ 1000,
      toTime: to == null ? null : to.millisecondsSinceEpoch ~/ 1000,
      cameraIds: cameraId == null ? null : '$cameraId',
      locked: locked,
      mode: mode == null ? null : '$mode',
    );
    final raw = _eventsOf(data);
    return raw
        .whereType<Map>()
        .map((e) =>
            Recording.fromEventJson(Map<String, dynamic>.from(e), cameraNames))
        .toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
  }

  /// 通知页数据源：同样取真实录像/告警事件（SS 无独立的移动端通知推送 API，
  /// 推送需在 DSM 通知服务里配置；App 内展示 NAS 上真实发生的事件）。
  Future<List<SurveillanceEvent>> events({
    required Map<int, String> cameraNames,
    int limit = 50,
  }) async {
    final recs = await recordings(cameraNames: cameraNames, limit: limit);
    return recs.map(SurveillanceEvent.fromRecording).toList();
  }

  /// SS 事件日志（若该版本支持），作为通知的补充真实来源。
  Future<List<Map<String, dynamic>>> logEntries({int limit = 50}) async {
    final data = await _client.queryLog(limit: limit);
    if (data == null) return <Map<String, dynamic>>[];
    final raw = data['logs'] ?? data['events'] ?? data['list'];
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  List<dynamic> _eventsOf(Map<String, dynamic> data) {
    final raw = data['events'] ??
        data['recordings'] ??
        data['recordingsList'] ??
        data['list'];
    return raw is List ? raw : <dynamic>[];
  }

  /// 事件总数（用于分页/「共 N 条」展示，来自真实响应）。
  int totalOf(Map<String, dynamic> data) {
    final v = data['total'];
    return v is num ? v.toInt() : _eventsOf(data).length;
  }

  Future<void> setLocked(String id, bool locked) =>
      _client.setRecordingLocked(id, locked);

  Future<void> deleteRecording(String id) => _client.deleteRecording(id);

  /// 下载真实录像片段字节，供 App 内播放器使用（不再默认跳浏览器）。
  Future<RecordingFile> downloadRecording(Recording r) =>
      _client.downloadRecording(r);

  /// 仅用于「复制链接」等用户主动操作。
  String downloadUrl(String id) => _client.recordingDownloadUrl(id);
}
