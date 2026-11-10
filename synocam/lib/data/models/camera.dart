// 摄像机模型：字段对齐 SYNO.SurveillanceStation.Camera / List 返回结构。
// SS 各版本字段名不稳定（camelCase / 全小写 / streamInfo 嵌套），故做宽松解析。
// 关键：StmKey 是 MJPEG 直播流的必需参数，必须从 List(streamInfo=true) 的
// 返回或 GetLiveViewPath 的完整 URL 中解析出来，否则直播无法播放。
class Camera {
  const Camera({
    required this.id,
    required this.name,
    this.model = '',
    this.ip = '',
    this.serial = '',
    this.enabled = true,
    this.status = 1,
    this.quality = '',
    this.codec = '',
    this.stmKey,
    this.livePath,
    this.ptzCapable = false,
  });

  final int id;
  final String name;
  final String model;
  final String ip;
  final String serial;
  final bool enabled;

  /// SS 状态码：1 = 正常在线，其它值参考 SS 状态码。
  final int status;
  final String quality;
  final String codec;

  /// 直播流分享密钥（MJPEG Stream 需要）。
  final String? stmKey;

  /// SS 直接返回的完整直播路径（若 List 已给出，优先使用）。
  final String? livePath;
  final bool ptzCapable;

  bool get isOnline => enabled && status == 1;

  /// 是否具备可用的直播流凭证。
  bool get canStream =>
      (stmKey != null && stmKey!.isNotEmpty) ||
      (livePath != null && livePath!.isNotEmpty);

  Camera copyWith({
    String? name,
    bool? enabled,
    String? quality,
    String? codec,
    String? model,
    String? ip,
    String? serial,
    String? stmKey,
    String? livePath,
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
        stmKey: stmKey ?? this.stmKey,
        livePath: livePath ?? this.livePath,
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
      if (v is bool) return v ? 1 : 0;
      if (v is String) {
        final n = int.tryParse(v);
        if (n != null) return n;
        // 部分版本用 "normal" / "connected" 等字符串表示在线。
        if (v.toLowerCase() == 'normal' || v.toLowerCase() == 'connected') {
          return 1;
        }
      }
    }
    return fallback;
  }

  /// 从任意嵌套层级里找出 StmKey。
  /// GetLiveViewPath 返回形如 ...&StmKey="abc" 的完整 URL，需正则提取。
  static String? _findStmKey(dynamic node) {
    if (node is String) {
      final m = RegExp(r'StmKey[=":\s]*"?([A-Za-z0-9_\-]{8,})"?',
              caseSensitive: false)
          .firstMatch(node);
      if (m != null) return m.group(1);
      return null;
    }
    if (node is Map) {
      for (final k in <String>[
        'stmKey',
        'StmKey',
        'StmKeymjpegHttp',
        'stmKeymjpegHttp',
        'mjpegHttpPath',
        'stmKeyUnicst',
      ]) {
        final v = node[k];
        if (v != null && v.toString().isNotEmpty) return v.toString();
      }
      for (final v in node.values) {
        final found = _findStmKey(v);
        if (found != null) return found;
      }
    }
    if (node is List) {
      for (final v in node) {
        final found = _findStmKey(v);
        if (found != null) return found;
      }
    }
    return null;
  }

  static String? _findLivePath(dynamic node) {
    if (node is String &&
        node.contains('method=Stream') &&
        node.contains('://')) {
      return node;
    }
    if (node is Map) {
      for (final v in node.values) {
        final found = _findLivePath(v);
        if (found != null) return found;
      }
    }
    if (node is List) {
      for (final v in node) {
        final found = _findLivePath(v);
        if (found != null) return found;
      }
    }
    return null;
  }

  factory Camera.fromSynoJson(Map<String, dynamic> j) {
    final enabledRaw = j['enabled'] ?? j['enable'];
    final status = _pickInt(j, <String>['status', 'camStatus', 'recStatus'], 1);
    final id = _pickInt(j, <String>['id', 'cameraId', 'camId']);
    return Camera(
      id: id,
      name: _pick(j, <String>['name', 'newName', 'camName'], '摄像机 #$id'),
      model: _pick(j, <String>['model', 'camModel', 'brand', 'vendor']),
      ip: _pick(j, <String>['ip', 'host', 'cameraIp', 'ipAddress', 'camIp']),
      serial: _pick(j, <String>['serial', 'sn', 'serialNumber']),
      enabled: enabledRaw is bool
          ? enabledRaw
          : enabledRaw is num
              ? enabledRaw.toInt() != 0
              : enabledRaw is String
                  ? enabledRaw == '1' || enabledRaw.toLowerCase() == 'true'
                  : true,
      status: status,
      quality: _pick(j, <String>['quality', 'streamQuality', 'resolution']),
      codec: _pick(j, <String>['codec', 'videoCodec']),
      stmKey: _findStmKey(j),
      livePath: _findLivePath(j),
      ptzCapable: _pickInt(j, <String>['ptz', 'isPtz', 'ptzCapable']) != 0,
    );
  }

  /// 从 List 接口返回的 data 段解析。
  static List<Camera> listFromData(Map<String, dynamic> data) {
    final raw = data['cameras'] ?? data['camList'] ?? data['list'];
    if (raw is! List) return <Camera>[];
    return raw
        .whereType<Map>()
        .map((e) => Camera.fromSynoJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}
