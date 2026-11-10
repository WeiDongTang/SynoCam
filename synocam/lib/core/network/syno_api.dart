// Synology DSM / Surveillance Station Web API 常量、URL 构造与通用响应解析。
//
// 参考：
//  - Synology《Surveillance Station Web API》(SS 6.x–9.x)
//  - Synology《DSM Login Web API Guide》
//  - 实证：Camera/List 需带 streamInfo=true&camStm=1 才返回 StmKey；
//    MJPEG 直播流为 SYNO.SurveillanceStation.Stream.VideoStreaming/Stream；
//    录像事件为 SYNO.SurveillanceStation.Event/Query（method 首字母大写）。
//
// 本文件为纯 Dart（不依赖 Flutter / dio），可在无 SDK 的 CI 里被单元测试。

import 'dart:convert';

/// DSM / Surveillance Station CGI 端点与默认端口。
class SynoEndpoints {
  SynoEndpoints._();

  static const String authCgi = '/webapi/auth.cgi';
  static const String entryCgi = '/webapi/entry.cgi';
  static const String queryCgi = '/webapi/query.cgi';
  static const int httpPort = 5000;
  static const int httpsPort = 5001;

  /// 把 API Info 返回的 path（如 "entry.cgi"）拼成完整 CGI 路径。
  static String cgiFromPath(String? path) {
    if (path == null || path.trim().isEmpty) return entryCgi;
    final p = path.trim();
    if (p.startsWith('/')) return p;
    return '/webapi/$p';
  }
}

/// API 名称常量（SYNO.*）。
class SynoApi {
  SynoApi._();

  static const String info = 'SYNO.API.Info';
  static const String auth = 'SYNO.API.Auth';
  static const String camera = 'SYNO.SurveillanceStation.Camera';
  static const String ptz = 'SYNO.SurveillanceStation.PTZ';
  // 实证：直播流 API 名含 ".Stream." 段（GetLiveViewPath 返回值即此形式）。
  static const String videoStream =
      'SYNO.SurveillanceStation.Stream.VideoStreaming';
  // 部分 SS 版本用无 ".Stream." 段的别名，作为回退探测。
  static const String videoStreamAlt =
      'SYNO.SurveillanceStation.VideoStreaming';
  static const String recording = 'SYNO.SurveillanceStation.Recording';
  static const String snapshot = 'SYNO.SurveillanceStation.Snapshot';
  static const String event = 'SYNO.SurveillanceStation.Event';
  static const String log = 'SYNO.SurveillanceStation.Log';
  static const String externalEvent = 'SYNO.SurveillanceStation.ExternalEvent';
  static const String actionRule = 'SYNO.SurveillanceStation.ActionRule';
  static const String license = 'SYNO.SurveillanceStation.License';
  static const String homeMode = 'SYNO.SurveillanceStation.HomeMode';

  /// 各 API 的兜底版本；登录后应以 SYNO.API.Info 返回的 maxVersion 为准。
  static const Map<String, int> defaultVersions = <String, int>{
    info: 1,
    auth: 6,
    camera: 9,
    ptz: 4,
    videoStream: 1,
    videoStreamAlt: 1,
    recording: 4,
    snapshot: 2,
    event: 1,
    log: 1,
    externalEvent: 1,
    actionRule: 1,
    license: 1,
    homeMode: 1,
  };

  /// 我们实现时所依据的最高版本（避免盲目使用过新的 maxVersion 导致参数不兼容）。
  static const Map<String, int> preferredVersions = <String, int>{
    camera: 9,
    ptz: 4,
    videoStream: 1,
    videoStreamAlt: 1,
    recording: 4,
    event: 1,
    log: 1,
    license: 1,
    homeMode: 1,
  };
}

/// 常用 method 常量，避免各处硬编码拼写不一致。
/// 注意大小写：SYNO.API.Info 用小写 query；SS Event 用大写 Query。
class SynoMethod {
  SynoMethod._();

  static const String queryApiInfo = 'query';
  static const String queryEvents = 'Query';
  static const String login = 'login';
  static const String logout = 'logout';
  static const String list = 'List';
  static const String getInfo = 'GetInfo';
  static const String getSnapshot = 'GetSnapshot';
  static const String getLiveViewPath = 'GetLiveViewPath';
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
  static const String switchMode = 'Switch';
  static const String record = 'Record';
}

/// 构造 DSM Web API 的完整 URL。
///
/// [host] 形如 `192.168.1.10` / `nas.example.com`（可带 scheme 与端口）。
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

/// SYNO.API.Info / query 返回的单条 API 描述。
class SynoApiInfoEntry {
  const SynoApiInfoEntry({
    required this.name,
    required this.maxVersion,
    required this.minVersion,
    required this.path,
  });

  final String name;
  final int maxVersion;
  final int minVersion;
  final String path;

  factory SynoApiInfoEntry.from(String name, Map<String, dynamic> j) =>
      SynoApiInfoEntry(
        name: name,
        maxVersion: (j['maxVersion'] as num?)?.toInt() ?? 1,
        minVersion: (j['minVersion'] as num?)?.toInt() ?? 1,
        path: j['path'] as String? ?? 'entry.cgi',
      );

  /// 该 API 实际应使用的版本：取 NAS 支持上限与我们实现依据上限的较小值。
  int effectiveVersion() {
    final preferred = SynoApi.preferredVersions[name];
    final ceiling = preferred ?? maxVersion;
    final v = maxVersion < ceiling ? maxVersion : ceiling;
    return v < minVersion ? minVersion : v;
  }

  String get cgi => SynoEndpoints.cgiFromPath(path);
}

/// 解析 SYNO.API.Info 的 data 段。
Map<String, SynoApiInfoEntry> parseApiInfo(Map<String, dynamic> data) {
  final out = <String, SynoApiInfoEntry>{};
  data.forEach((k, v) {
    if (v is Map) {
      out[k] = SynoApiInfoEntry.from(k, Map<String, dynamic>.from(v));
    }
  });
  return out;
}

/// DSM / SS 错误码。
///
/// 400–410 来自《DSM Login Web API Guide》SYNO.API.Auth "API Error Codes"；
/// 100–119 为 DSM 通用错误码。2FA 账号不带 otp_code 时返回 403（需验证码），
/// 验证码错误 404，强制 2FA 406，账号或密码错误 400。
class SynoErrorCode {
  SynoErrorCode._();

  static const int unknown = 100;
  static const int invalidParameter = 101;
  static const int apiNotExist = 102;
  static const int methodNotExist = 103;
  static const int versionNotSupported = 104;
  static const int noPermission = 105;
  static const int sessionTimeout = 106;
  static const int duplicateLogin = 107;
  static const int invalidSession = 119;

  /// DSM nginx 自定义状态码：会话失效 / 需要重新登录。
  /// 与官方 JSON 错误码 106/119 描述同一状态，但在外网 / DDNS / QuickConnect
  /// 场景下 DSM 常不返回 JSON，而是 HTTP 465 + 一段登录页 HTML。
  static const int portalAuthRequired = 465;

  static const int badCredentials = 400;
  static const int accountDisabled = 401;
  static const int permissionDenied = 402;
  static const int otpRequired = 403;
  static const int otpInvalid = 404;
  static const int otpEnforced = 406;
  static const int ipBlocked = 407;
  static const int passwordExpiredNoChange = 408;
  static const int passwordExpired = 409;
  static const int passwordMustChange = 410;

  /// 登录来源 IP 与登录时不一致（蜂窝网络切换 / DDNS 出口变化时会触发）。
  static const int ipMismatch = 150;

  static const int invalidAccount = badCredentials;
  static const int wrongPassword = badCredentials;
  static const int needTwoFactor = otpRequired;

  /// API 或方法不存在：用于「该 NAS 版本不支持此接口」的回退判定。
  static bool isUnsupported(int code) =>
      code == apiNotExist ||
      code == methodNotExist ||
      code == versionNotSupported;

  static String describe(int code) {
    const m = <int, String>{
      100: '未知错误',
      101: '参数无效',
      102: 'API 不存在（请确认已安装并启用 Surveillance Station）',
      103: '该 API 不支持此方法',
      104: '该 API 版本不受支持',
      105: '当前账号无权限执行此操作',
      106: '会话已超时，请重新登录',
      107: '会话被重复登录挤下线',
      119: '会话无效，请重新登录',
      465: '登录会话已过期或被 NAS 登出，请重新登录（DSM 门户拦截）',
      150: '登录来源 IP 已变化，请重新登录',
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

  bool get needsReLogin =>
      code == SynoErrorCode.sessionTimeout ||
      code == SynoErrorCode.duplicateLogin ||
      code == SynoErrorCode.permissionDenied ||
      code == SynoErrorCode.invalidSession ||
      code == SynoErrorCode.portalAuthRequired ||
      code == SynoErrorCode.ipMismatch;

  bool get needsOtp =>
      code == SynoErrorCode.otpRequired ||
      code == SynoErrorCode.otpInvalid ||
      code == SynoErrorCode.otpEnforced;

  bool get otpRejected => code == SynoErrorCode.otpInvalid;

  /// 供 UI 展示「错误码」，便于用户反馈时精确定位（本环境无法直连 NAS）。
  String get diagnostic =>
      message.contains('错误码') ? message : '$message（错误码 $code）';

  @override
  String toString() => 'SynoException($code): $message';
}

/// 把「HTTP 状态 + 非 JSON 响应体」分类为可执行的 [SynoException]。
///
/// DSM 在外网 / DDNS / QuickConnect 场景下，SID 过期或被 NAS 登出时，Web API
/// 端点常不返回官方 JSON 错误码（106/119），而是：
///  * HTTP 465（DSM / nginx 自定义状态码）+ 一段登录页 HTML；或
///  * HTTP 200 + 登录页 HTML（被门户重定向）。
/// 这类响应必须归为「会话失效」以触发重新登录。旧实现一律降级为
/// `错误码 100 + 请检查地址/端口/HTTPS`，把用户引向完全错误的排查方向，
/// 且 App 会卡在「显示已登录、实则僵尸会话」的死局。
///
/// 纯函数：可在无 Flutter / 无网络的自检里直接覆盖。
SynoException classifyHttpResponse(int statusCode, String body) {
  final head = body.trimLeft().toLowerCase();
  final lower = body.toLowerCase();
  final isHtml = head.startsWith('<!doctype') ||
      head.startsWith('<html') ||
      head.startsWith('<head') ||
      head.startsWith('<body') ||
      (head.contains('<html') && head.contains('<meta'));
  // 登录页 / DSM 门户页的典型特征。
  final looksLikeLoginPage = isHtml &&
      (lower.contains('synology') ||
          lower.contains('dsm') ||
          lower.contains('login') ||
          lower.contains('width=device-width') ||
          lower.contains('viewport'));

  final sessionInvalid = statusCode == SynoErrorCode.portalAuthRequired ||
      statusCode == SynoErrorCode.ipMismatch ||
      looksLikeLoginPage ||
      (statusCode == 200 && isHtml) ||
      (statusCode == 0 && isHtml);

  if (sessionInvalid) {
    final suffix = statusCode > 0 ? '（HTTP $statusCode）' : '';
    return SynoException(
        SynoErrorCode.portalAuthRequired, '登录会话已过期或被 NAS 登出，请重新登录$suffix');
  }
  if (isHtml) {
    // 其它网页（如 404 / nginx 错误页）保留地址类建议，避免误判会话。
    return SynoException(SynoErrorCode.unknown,
        'NAS 返回了网页而非 API 数据（HTTP $statusCode），请检查地址/端口/HTTPS 设置');
  }
  return SynoException(SynoErrorCode.unknown,
      '服务器返回的不是 JSON（HTTP $statusCode），请检查地址/端口/HTTPS 设置');
}

/// 面向 UI 的错误分类：让各页面按真实错误类型显示建议，而不是写死
/// 「请检查地址/端口/HTTPS」「确认账号具备权限」这类误导性副标题。
enum FailureKind { session, certificate, network, permission, other }

class FailureView {
  const FailureView(this.kind, this.title, this.advice);

  final FailureKind kind;
  final String title;
  final String advice;

  bool get needsReLogin => kind == FailureKind.session;
}

/// 把任意异常或错误文本归类。UI 层拿到的往往是字符串（e.diagnostic），
/// 因此同时支持 [SynoException] 对象与文本关键词两种输入。
FailureView classifyFailure(Object? error) {
  const session = FailureView(
      FailureKind.session,
      '登录会话已过期',
      'NAS 已拒绝当前会话（常见于外网 / DDNS 放置一段时间后或手机网络切换）。'
          '请重新登录；连接信息已为你保留，只需重输密码。');
  if (error is SynoException) {
    if (error.needsReLogin) return session;
    switch (error.code) {
      case SynoErrorCode.noPermission:
      case SynoErrorCode.permissionDenied:
        return const FailureView(FailureKind.permission, '权限不足',
            '请确认该账号在 DSM 中具备 Surveillance Station 的访问权限。');
      case SynoErrorCode.badCredentials:
      case SynoErrorCode.otpRequired:
      case SynoErrorCode.otpInvalid:
      case SynoErrorCode.otpEnforced:
        return FailureView(FailureKind.other, '登录被拒绝', error.message);
    }
  }
  final s = error == null ? '' : error.toString();
  if (s.contains('会话') &&
          (s.contains('过期') || s.contains('失效') || s.contains('已过期')) ||
      s.contains('重新登录') ||
      s.contains('登录会话') ||
      s.contains('HTTP 465') ||
      s.contains('被 NAS 登出')) {
    return session;
  }
  if (s.contains('证书') || s.contains('自签')) {
    return const FailureView(FailureKind.certificate, 'HTTPS 证书不受信任',
        '若 NAS 使用自签名证书，请在「设置」开启「信任自签名 HTTPS 证书」。');
  }
  if (s.contains('超时') || s.contains('网络错误') || s.contains('无法连接')) {
    return const FailureView(
        FailureKind.network, '网络连接失败', '请检查手机网络、NAS 地址 / 端口与 DSM 服务是否在线。');
  }
  if (s.contains('权限') || s.contains('错误码 105') || s.contains('错误码 402')) {
    return const FailureView(FailureKind.permission, '权限不足',
        '请确认该账号在 DSM 中具备 Surveillance Station 的访问权限。');
  }
  return const FailureView(
      FailureKind.other, '读取失败', '以上为 NAS 返回的真实响应，可据此定位接口 / 版本 / 权限问题。');
}

/// 统一的「该错误是否需要重新登录」判定，供任意页面 / 组件调用。
/// 同时覆盖 [SynoException] 对象、MjpegException（toString 含会话文案）
/// 与 e.diagnostic 这类纯文本，避免各处重复实现关键词匹配。
bool needsReLoginError(Object? error) {
  if (error is SynoException && error.needsReLogin) return true;
  return classifyFailure(error).needsReLogin;
}
