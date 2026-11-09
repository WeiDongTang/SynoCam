// Synology DSM / Surveillance Station Web API 常量、URL 构造与通用响应解析。
//
// 参考：DSM「SYNO.API.*」通用约定 + Surveillance Station 9.x Web API。
// 本文件为纯 Dart（不依赖 Flutter / dio），可在无 SDK 的 CI 里被单元测试。
// 真实登录 → 取 SID → 带 _sid 调 entry.cgi 的完整链路见 syno_client.dart。

import 'dart:convert';

/// DSM / Surveillance Station CGI 端点与默认端口。
class SynoEndpoints {
  SynoEndpoints._();

  static const String authCgi = '/webapi/auth.cgi';
  static const String entryCgi = '/webapi/entry.cgi';
  static const String queryCgi = '/webapi/query.cgi';
  static const int httpPort = 5000;
  static const int httpsPort = 5001;
}

/// API 名称常量（SYNO.*）。
class SynoApi {
  SynoApi._();

  static const String info = 'SYNO.API.Info';
  static const String auth = 'SYNO.API.Auth';
  static const String camera = 'SYNO.SurveillanceStation.Camera';
  static const String ptz = 'SYNO.SurveillanceStation.PTZ';
  static const String videoStream =
      'SYNO.SurveillanceStation.Stream.VideoStreaming';
  static const String recording = 'SYNO.SurveillanceStation.Recording';
  static const String snapshot = 'SYNO.SurveillanceStation.Snapshot';
  static const String event = 'SYNO.SurveillanceStation.Event';
  static const String externalEvent = 'SYNO.SurveillanceStation.ExternalEvent';
  static const String actionRule = 'SYNO.SurveillanceStation.ActionRule';
  static const String license = 'SYNO.SurveillanceStation.License';
  static const String homeMode = 'SYNO.SurveillanceStation.HomeMode';

  /// 各 API 的兜底版本；实际应以 SYNO.API.Info 返回的 maxVersion 为准。
  static const Map<String, int> defaultVersions = <String, int>{
    info: 1,
    auth: 6,
    camera: 9,
    ptz: 4,
    videoStream: 1,
    recording: 6,
    snapshot: 2,
    event: 6,
    externalEvent: 1,
    actionRule: 1,
    license: 1,
    homeMode: 1,
  };
}

/// 常用 method 常量，避免各处硬编码拼写不一致。
class SynoMethod {
  SynoMethod._();

  static const String query = 'query';
  static const String login = 'login';
  static const String logout = 'logout';
  static const String list = 'List';
  static const String getInfo = 'GetInfo';
  static const String getSnapshot = 'GetSnapshot';
  static const String enable = 'Enable';
  static const String disable = 'Disable';
  static const String save = 'Save';
  static const String stream = 'Stream';
  static const String move = 'Move';
  static const String zoom = 'Zoom';
  static const String listPreset = 'ListPreset';
  static const String goPreset = 'GoPreset';
  static const String runPatrol = 'RunPatrol';
  static const String lock = 'Lock';
  static const String unlock = 'Unlock';
  static const String download = 'Download';
  static const String delete = 'Delete';
}

/// 构造 DSM Web API 的完整 URL。
///
/// [base] 形如 `192.168.1.10` 或 `nas.example.com`（不含 scheme / 端口时可省略 port）。
/// [cgi] 为 SynoEndpoints 中的路径；[query] 中的 null 值会被自动剔除。
String buildSynoUrl({
  required String host,
  required String cgi,
  required Map<String, String?> query,
  bool https = false,
  int? port,
}) {
  var h = host.trim();
  var p = port;
  // 若 host 里已带 scheme / 端口，拆分出来，保证 Uri 构造正确。
  if (h.startsWith('https://')) {
    https = true;
    h = h.substring(8);
  } else if (h.startsWith('http://')) {
    https = false;
    h = h.substring(7);
  }
  final slash = h.indexOf('/');
  if (slash >= 0) h = h.substring(0, slash);
  final colon = h.lastIndexOf(':');
  if (colon > 0 && p == null) {
    p = int.tryParse(h.substring(colon + 1));
    h = h.substring(0, colon);
  }
  p ??= https ? SynoEndpoints.httpsPort : SynoEndpoints.httpPort;

  final cleaned = <String, String>{};
  query.forEach((k, v) {
    if (v != null) cleaned[k] = v;
  });

  return Uri(
    scheme: https ? 'https' : 'http',
    host: h,
    port: p,
    path: cgi,
    queryParameters: cleaned,
  ).toString();
}

/// 通用 API 响应信封：{ "success": bool, "data": {...}, "error": { "code": int } }
class SynoResponse {
  SynoResponse({required this.success, this.data, this.error});

  final bool success;
  final Map<String, dynamic>? data;
  final SynoApiError? error;

  factory SynoResponse.fromJson(Map<String, dynamic> json) {
    final err = json['error'];
    return SynoResponse(
      success: json['success'] == true,
      data: json['data'] is Map
          ? Map<String, dynamic>.from(json['data'] as Map)
          : null,
      error: err is Map
          ? SynoApiError(code: (err['code'] as num?)?.toInt() ?? 0)
          : null,
    );
  }

  factory SynoResponse.fromBody(String body) =>
      SynoResponse.fromJson(jsonDecode(body) as Map<String, dynamic>);

  /// 取出 data，失败时抛出携带可读信息的异常。
  Map<String, dynamic> requireData() {
    if (!success || data == null) {
      throw SynoException.fromCode(error?.code ?? SynoErrorCode.unknown);
    }
    return data!;
  }

  @override
  String toString() =>
      'SynoResponse(success=$success, code=${error?.code}, keys=${data?.keys.toList()})';
}

class SynoApiError {
  const SynoApiError({required this.code});
  final int code;
}

/// DSM / SS 常见错误码（不同套件版本略有差异，未命中时降级为通用描述）。
class SynoErrorCode {
  SynoErrorCode._();

  static const int unknown = 100;
  static const int invalidParameter = 101;
  static const int apiNotExist = 102;
  static const int methodNotExist = 103;
  static const int versionNotSupported = 104;
  static const int sessionTimeout = 106;
  static const int duplicateLogin = 107;
  static const int invalidAccount = 400;
  static const int accountDisabled = 401;
  static const int permissionDenied = 402;
  static const int wrongPassword = 403;
  static const int needTwoFactor = 404;
  static const int otpRequired = 405;
  static const int ipBlocked = 407;
  static const int passwordExpired = 408;

  static String describe(int code) {
    const m = <int, String>{
      100: '未知错误',
      101: '参数无效',
      102: 'API 不存在（请确认已安装 Surveillance Station）',
      103: '方法不存在',
      104: '该 API 版本不受支持',
      105: '当前账号无权限执行此操作',
      106: '会话已超时，请重新登录',
      107: '会话被重复登录挤下线',
      400: '账号不存在或密码错误',
      401: '账号已被停用',
      402: '权限不足',
      403: '密码错误',
      404: '需要两步验证验证码',
      405: '需要一次性验证码（OTP）',
      406: '需要强制修改密码',
      407: 'IP 已被临时封锁',
      408: '密码已过期',
    };
    return m[code] ?? '请求失败（错误码 $code）';
  }
}

/// 统一异常：携带 DSM/SS 错误码与可读信息，供 UI 层直接展示。
class SynoException implements Exception {
  SynoException(this.code, [String? detail])
      : message = detail ?? SynoErrorCode.describe(code);

  final int code;
  final String message;

  factory SynoException.fromCode(int code) => SynoException(code);

  /// 会话类错误 → UI 应触发重新登录。
  bool get needsReLogin =>
      code == SynoErrorCode.sessionTimeout ||
      code == SynoErrorCode.duplicateLogin ||
      code == SynoErrorCode.permissionDenied;

  @override
  String toString() => 'SynoException($code): $message';
}
