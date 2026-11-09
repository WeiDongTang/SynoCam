// 录像、快照与事件模型（对应 Recording / Snapshot / Event 三个 SS API）。
class Recording {
  const Recording({
    required this.id,
    required this.cameraId,
    required this.cameraName,
    required this.startTime,
    required this.durationSeconds,
    this.locked = false,
    this.eventType = '连续录制',
  });

  final String id;
  final int cameraId;
  final String cameraName;
  final DateTime startTime;
  final int durationSeconds;
  final bool locked;
  final String eventType;

  String get durationLabel {
    final m = durationSeconds ~/ 60;
    final s = durationSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

class SurveillanceEvent {
  const SurveillanceEvent({
    required this.id,
    required this.title,
    required this.time,
    required this.type,
    this.read = false,
    this.cameraId,
  });

  final String id;
  final String title;
  final DateTime time;

  /// motion / alarm / door / dva / system
  final String type;
  final bool read;
  final int? cameraId;
}
