// 摄像机模型：字段对齐 SYNO.SurveillanceStation.Camera / GetInfo 返回结构。
// SS API 的字段名并不稳定（不同版本有 camelCase / 全小写差异），故解析时做了兼容。
class Camera {
  const Camera({
    required this.id,
    required this.name,
    this.model = '',
    this.ip = '',
    this.serial = '',
    this.enabled = true,
    this.status = 1,
    this.quality = '4MP',
    this.codec = 'H.265',
    this.stmKey,
    this.ptzCapable = false,
  });

  final int id;
  final String name;
  final String model;
  final String ip;
  final String serial;
  final bool enabled;

  /// 1 = 正常在线，其它值参考 SS 状态码。
  final int status;
  final String quality;
  final String codec;

  /// 直播流分享密钥（VideoStreaming/Stream 需要，从 SS 分享串流路径获得）。
  final String? stmKey;
  final bool ptzCapable;

  bool get isOnline => enabled && status == 1;

  Camera copyWith({
    String? name,
    bool? enabled,
    String? quality,
    String? codec,
    String? model,
    String? ip,
    String? serial,
  }) =>
      Camera(
        id: id,
        name: name ?? this.name,
        model: model ?? this.model,
        ip: ip ?? this.ip,
        serial: serial ?? this.serial,
        enabled: enabled ?? this.enabled,
        status: status,
        quality: quality ?? this.quality,
        codec: codec ?? this.codec,
        stmKey: stmKey,
        ptzCapable: ptzCapable,
      );

  static String _pick(Map<String, dynamic> j, List<String> keys,
      [String fallback = '']) {
    for (final k in keys) {
      final v = j[k];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    return fallback;
  }

  static int _pickInt(Map<String, dynamic> j, List<String> keys,
      [int fallback = 0]) {
    for (final k in keys) {
      final v = j[k];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? fallback;
    }
    return fallback;
  }

  factory Camera.fromSynoJson(Map<String, dynamic> j) {
    final enabledRaw = j['enabled'] ?? j['enable'] ?? j['status'];
    final status = _pickInt(j, <String>['status', 'camStatus'], 1);
    return Camera(
      id: _pickInt(j, <String>['id', 'cameraId', 'camId']),
      name: _pick(j, <String>['name', 'camName', 'newName'], '摄像机'),
      model: _pick(j, <String>['model', 'camModel', 'brand']),
      ip: _pick(j, <String>['ip', 'host', 'cameraIp', 'ipAddress']),
      serial: _pick(j, <String>['serial', 'sn', 'serialNumber']),
      enabled: enabledRaw is bool
          ? enabledRaw
          : enabledRaw is num
              ? enabledRaw.toInt() != 0
              : true,
      status: status,
      ptzCapable: _pickInt(j, <String>['ptz', 'isPtz', 'ptzCapable']) != 0,
    );
  }

  /// 从 List 接口返回的 `data.cameras` 数组解析。
  static List<Camera> listFromData(Map<String, dynamic> data) {
    final raw = data['cameras'] ?? data['camera'] ?? data['list'];
    if (raw is! List) return <Camera>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(Camera.fromSynoJson)
        .toList();
  }
}
