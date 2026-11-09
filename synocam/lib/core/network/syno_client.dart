// Synology DSM / Surveillance Station Web API 客户端。
//
// 链路：auth.cgi 登录 → 拿到 data.sid → 之后每个 entry.cgi 请求带 _sid。
// 所有请求统一走 _request()，集中处理错误码映射、会话失效重登与超时。
// 仅负责「协议」，业务语义由 data/repositories 组装。

import 'package:dio/dio.dart';

import '../config/app_config.dart';
import 'syno_api.dart';
import '../../data/models/syno_session.dart';

class SynoClient {
  SynoClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: AppConfig.connectTimeout,
              receiveTimeout: AppConfig.receiveTimeout,
              // 用户自建 NAS 常用自签证书；默认不在此处放宽校验，
              // 是否信任自签证书应由 UI 显式开关决定（见 SecuritySettings）。
              validateStatus: (s) => s != null && s < 500,
            ));

  final Dio _dio;
  SynoSession? _session;

  SynoSession? get session => _session;
  bool get isLoggedIn => _session != null;

  /// 冷启动恢复会话（「记住我」）。恢复后若 SID 已过期，首个请求会返回
  /// 106/107，由 UI 依据 SynoException.needsReLogin 触发重新登录。
  void restoreSession(SynoSession session) => _session = session;

  String _stripScheme(String h) {
    var s = h.trim();
    if (s.startsWith('https://')) s = s.substring(8);
    if (s.startsWith('http://')) s = s.substring(7);
    final slash = s.indexOf('/');
    if (slash >= 0) s = s.substring(0, slash);
    return s;
  }

  /// 登录。成功返回 SynoSession（含 SID）；失败抛 SynoException。
  Future<SynoSession> login({
    required String host,
    required String account,
    required String password,
    bool https = false,
    int? port,
    String? otpCode,
  }) async {
    final p =
        port ?? (https ? SynoEndpoints.httpsPort : SynoEndpoints.httpPort);
    final url = buildSynoUrl(
      host: host,
      cgi: SynoEndpoints.authCgi,
      https: https,
      port: p,
      query: <String, String?>{
        'api': SynoApi.auth,
        'version': '${AppConfig.authVersion}',
        'method': SynoMethod.login,
        'account': account,
        'passwd': password,
        'session': AppConfig.sessionName,
        'format': AppConfig.sidFormat,
        'otp_code': otpCode,
      },
    );

    final resp = await _getRaw(url);
    final data = resp.requireData();
    final sid = data['sid'] as String?;
    if (sid == null || sid.isEmpty) {
      throw SynoException(SynoErrorCode.unknown, '登录成功但未返回 SID');
    }
    _session = SynoSession(
      sid: sid,
      host: _stripScheme(host),
      account: account,
      https: https,
      port: p,
      did: data['did'] as String?,
    );
    return _session!;
  }

  /// 退出登录：调用 Auth/logout 并在本地清除会话（失败也清除）。
  Future<void> logout() async {
    final s = _session;
    _session = null;
    if (s == null) return;
    final url = buildSynoUrl(
      host: s.host,
      cgi: SynoEndpoints.authCgi,
      https: s.https,
      port: s.port,
      query: <String, String?>{
        'api': SynoApi.auth,
        'version': '${AppConfig.authVersion}',
        'method': SynoMethod.logout,
        'session': AppConfig.sessionName,
        '_sid': s.sid,
      },
    );
    try {
      await _dio.get<dynamic>(url);
    } catch (_) {
      // 忽略网络异常，本地会话已清除。
    }
  }

  /// 调用一个 SYNO API（entry.cgi），自动附加 _sid 与 version。
  Future<Map<String, dynamic>> call({
    required String api,
    required String method,
    Map<String, String?>? params,
    int? version,
    ResponseType? responseType,
  }) async {
    final s = _session;
    if (s == null) {
      throw SynoException(SynoErrorCode.sessionTimeout, '尚未登录或会话已失效');
    }
    final v = version ?? SynoApi.defaultVersions[api] ?? 1;
    final url = buildSynoUrl(
      host: s.host,
      cgi: SynoEndpoints.entryCgi,
      https: s.https,
      port: s.port,
      query: <String, String?>{
        'api': api,
        'version': '$v',
        'method': method,
        '_sid': s.sid,
        ...?params,
      },
    );

    if (responseType == ResponseType.bytes) {
      final r = await _dio.get<List<int>>(url,
          options: Options(responseType: ResponseType.bytes));
      return <String, dynamic>{'bytes': r.data};
    }

    final resp = await _getRaw(url);
    return resp.requireData();
  }

  /// 拉取摄像机列表。
  Future<List<Map<String, dynamic>>> listCameras() async {
    final data = await call(api: SynoApi.camera, method: SynoMethod.list);
    final raw = data['cameras'] ?? data['camera'] ?? data['list'];
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw.whereType<Map<String, dynamic>>().toList();
  }

  /// 快照：返回 JPEG 字节（SS 的 GetSnapshot 直接返回二进制）。
  Future<List<int>> getSnapshot(int cameraId) async {
    final data = await call(
      api: SynoApi.camera,
      method: SynoMethod.getSnapshot,
      params: <String, String?>{'cameraId': '$cameraId'},
      responseType: ResponseType.bytes,
    );
    final bytes = data['bytes'];
    if (bytes is List<int>) return bytes;
    throw SynoException(SynoErrorCode.unknown, '快照为空或格式异常');
  }

  /// 快照 URL（供 Image.network 直接用，避免重复二进制封装）。
  String snapshotUrl(int cameraId) {
    final s = _session!;
    return buildSynoUrl(
      host: s.host,
      cgi: SynoEndpoints.entryCgi,
      https: s.https,
      port: s.port,
      query: <String, String?>{
        'api': SynoApi.camera,
        'version': '${SynoApi.defaultVersions[SynoApi.camera]}',
        'method': SynoMethod.getSnapshot,
        'cameraId': '$cameraId',
        '_sid': s.sid,
      },
    );
  }

  /// MJPEG 直播流 URL（对应官方「分享串流路径」里的 cameraId + StmKey）。
  /// 生产环境建议改用 RTSP/原生播放器插件以获得 H.265 硬解，此处给出可直接
  /// 在 <img>/Image 中轮询的兼容通道，作为直播骨架。
  String liveStreamUrl({required int cameraId, required String stmKey}) {
    final s = _session!;
    return buildSynoUrl(
      host: s.host,
      cgi: SynoEndpoints.entryCgi,
      https: s.https,
      port: s.port,
      query: <String, String?>{
        'api': SynoApi.videoStream,
        'version': '${SynoApi.defaultVersions[SynoApi.videoStream]}',
        'method': SynoMethod.stream,
        'format': 'mjpeg',
        'cameraId': '$cameraId',
        'StmKey': stmKey,
        '_sid': s.sid,
      },
    );
  }

  /// PTZ 移动 / 变焦 / 预置位 / 巡逻。
  Future<void> ptz(String method, int cameraId,
      {Map<String, String?>? extra}) async {
    await call(
      api: SynoApi.ptz,
      method: method,
      params: <String, String?>{'cameraId': '$cameraId', ...?extra},
    );
  }

  /// 启用 / 停用摄像机（SS 用 idList 逗号分隔）。
  Future<void> setCameraEnabled(List<int> ids, bool enabled) async {
    await call(
      api: SynoApi.camera,
      method: enabled ? SynoMethod.enable : SynoMethod.disable,
      params: <String, String?>{'idList': ids.join(',')},
    );
  }

  /// 修改摄像机名称 / 流参数（Save）。
  Future<void> saveCamera(int cameraId, {String? name, String? quality}) async {
    await call(
      api: SynoApi.camera,
      method: SynoMethod.save,
      params: <String, String?>{
        'id': '$cameraId',
        'name': name,
        'quality': quality,
      },
    );
  }

  Future<SynoResponse> _getRaw(String url) async {
    try {
      final r = await _dio.get<dynamic>(url);
      final body = r.data;
      if (body is String) return SynoResponse.fromBody(body);
      if (body is Map) {
        return SynoResponse.fromJson(Map<String, dynamic>.from(body));
      }
      throw SynoException(SynoErrorCode.unknown, '无法解析服务器响应');
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw SynoException(SynoErrorCode.unknown, '连接超时，请检查地址与网络');
      }
      throw SynoException(SynoErrorCode.unknown, '网络错误：${e.message}');
    }
  }
}
