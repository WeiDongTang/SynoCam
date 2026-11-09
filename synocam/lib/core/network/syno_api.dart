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

/// DSM / SS 错误码。
///
/// 400–410 来自 Synology 官方《DSM Login Web API Guide》中
/// SYNO.API.Auth 的 "API Error Codes" 表；100–119 为 DSM 通用错误码。
///
/// 重要：账号开启两步验证（2FA）后，login 只带 passwd 不带 otp_code 时
/// 返回的是 **403（需要验证码）**，验证码错误返回 **404**。早期实现曾把
/// 403 误标成「密码错误」、把 404/405 当作「需要两步验证」，导致 2FA 用户
/// 看到误导性报错且 OTP 输入框永远不弹出 —— 本表已按官方定义校正。
class SynoErrorCode {
  SynoErrorCode._();

  // ── DSM 通用错误码 ──
  static const int unknown = 100;
  static const int invalidParameter = 101;
  static const int apiNotExist = 102;
  static const int methodNotExist = 103;
  static const int versionNotSupported = 104;
  static const int noPermission = 105;
  static const int sessionTimeout = 106;
  static const int duplicateLogin = 107;
  static const int invalidSession = 119;

  // ── SYNO.API.Auth / login 官方错误码 ──
  static const int badCredentials = 400; // 账号不存在或密码错误
  static const int accountDisabled = 401; // 账号已停用
  static const int permissionDenied = 402; // 权限不足
  static const int otpRequired = 403; // 需要两步验证码
  static const int otpInvalid = 404; // 两步验证码认证失败
  static const int otpEnforced = 406; // 强制要求启用 / 完成两步验证
  static const int ipBlocked = 407; // IP 已被封锁
  static const int passwordExpiredNoChange = 408; // 密码过期且不可自行修改
  static const int passwordExpired = 409; // 密码已过期
  static const int passwordMustChange = 410; // 必须修改密码

  // 兼容旧调用的别名（语义已按官方定义校正，勿再按字面理解）。
  static const int invalidAccount = badCredentials;
  static const int wrongPassword = badCredentials;
  static const int needTwoFactor = otpRequired;

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
      119: '会话无效，请重新登录',
      400: '账号不存在或密码错误',
      401: '账号已被停用',
      402: '权限不足，请确认账号具备 Surveillance Station 访问权限',
      403: '该账号已开启两步验证，请输入 6 位验证码',
      404: '两步验证码错误或已过期，请重新输入',
      406: '管理员要求必须完成两步验证，请先在 DSM 完成设置',
      407: 'IP 已被临时封锁，请稍后再试',
      408: '密码已过期且无法自行修改，请联系管理员',
      409: '密码已过期，请修改后重试',
      410: '首次登录或密码被重置，请先修改密码',
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
      code == SynoErrorCode.permissionDenied ||
      code == SynoErrorCode.invalidSession;

  /// 两步验证相关错误 → UI 应展开 / 保持 OTP 输入框并允许重新提交。
  /// 403 = 需要输入验证码；404 = 验证码错误需重试；406 = 强制要求 2FA。
  bool get needsOtp =>
      code == SynoErrorCode.otpRequired ||
      code == SynoErrorCode.otpInvalid ||
      code == SynoErrorCode.otpEnforced;

  /// 验证码被拒绝（区别于「首次需要输入验证码」），用于聚焦与文案。
  bool get otpRejected => code == SynoErrorCode.otpInvalid;

  @override
  String toString() => 'SynoException($code): $message';
}
