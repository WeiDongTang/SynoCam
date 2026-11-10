// Synology DSM / Surveillance Station Web API 客户端（真实链路，无演示数据）。
//
// 链路：auth.cgi 登录 → SID → SYNO.API.Info 动态发现各 API 的 path/maxVersion
// → 之后每个请求带 _sid 调对应 CGI。所有失败都抛出携带 DSM 错误码的
// SynoException，绝不静默吞掉后回退到假数据。

import 'dart:convert';

import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../../data/models/syno_session.dart';
import 'syno_api.dart';

class SynoClient {
  SynoClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: AppConfig.connectTimeout,
              receiveTimeout: AppConfig.receiveTimeout,
              // 4xx 也要读 body，DSM 把业务错误放在 HTTP 200 的 JSON 里，
              // 但部分网关/反向代理会返回 4xx + JSON，不能让 Dio 直接抛异常。
              validateStatus: (s) => s != null && s < 500,
            ));

  final Dio _dio;
  SynoSession? _session;
  Map<String, SynoApiInfoEntry> _apiInfo = <String, SynoApiInfoEntry>{};

  SynoSession? get session => _session;
  bool get isLoggedIn => _session != null;

  /// 登录成功后发现的 API 描述（供诊断页展示 NAS 实际支持的能力）。
  Map<String, SynoApiInfoEntry> get apiInfo => _apiInfo;

  void restoreSession(SynoSession session) => _session = session;

  String _stripScheme(String h) {
    var s = h.trim();
    if (s.startsWith('https://')) s = s.substring(8);
    if (s.startsWith('http://')) s = s.substring(7);
    final slash = s.indexOf('/');
    if (slash >= 0) s = s.substring(0, slash);
    return s;
  }

  int _versionFor(String api) =>
      _apiInfo[api]?.effectiveVersion() ??
      SynoApi.defaultVersions[api] ??
      1;

  String _cgiFor(String api) =>
      _apiInfo[api]?.cgi ?? SynoEndpoints.entryCgi;

  /// 查询 NAS 实际支持的 API 与版本。SS 各版本 endpoint/版本差异大，
  /// 硬编码必然在某些 NAS 上失效，故登录后立刻做一次能力发现。
  Future<void> discoverApis() async {
    final url = buildSynoUrl(
      host: _session?.host ?? '',
      cgi: SynoEndpoints.queryCgi,
      https: _session?.https ?? false,
      port: _session?.port,
      query: <String, String?>{
        'api': SynoApi.info,
        'version': '1',
        'method': SynoMethod.queryApiInfo,
        'query': <String>[
          SynoApi.auth,
          SynoApi.camera,
          SynoApi.ptz,
          SynoApi.videoStream,
          SynoApi.videoStreamAlt,
          SynoApi.recording,
          SynoApi.event,
          SynoApi.log,
          SynoApi.license,
          SynoApi.homeMode,
          SynoApi.snapshot,
        ].join(','),
      },
    );
    try {
      final r = await _dio.get<dynamic>(url);
      final body = r.data;
      final json = body is String
          ? jsonDecode(body) as Map<String, dynamic>
          : Map<String, dynamic>.from(body as Map);
      if (json['success'] == true && json['data'] is Map) {
        _apiInfo = parseApiInfo(Map<String, dynamic>.from(json['data'] as Map));
      }
    } catch (_) {
      // 能力发现失败不阻断登录：后续用 defaultVersions 兜底，
      // 但 UI 会显示「未能读取 NAS API 信息」以便排查。
      _apiInfo = <String, SynoApiInfoEntry>{};
    }
  }

  /// 登录。成功返回 SynoSession（含 SID）；失败抛 SynoException。
  Future<SynoSession> login({
    required String host,
    required String account,
    required String password,
    bool https = false,
    int? port,
    String? otpCode,
    bool enableDeviceToken = false,
    String? deviceId,
    String? deviceName,
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
        'otp_code': (otpCode == null || otpCode.isEmpty) ? null : otpCode,
        'enable_device_token': enableDeviceToken ? 'yes' : null,
        'device_id': deviceId,
        'device_name': deviceName,
      },
    );

    final data = (await _getRaw(url)).requireData();
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
    await discoverApis();
    return _session!;
  }

  Future<void> logout() async {
    final s = _session;
    _session = null;
    _apiInfo = <String, SynoApiInfoEntry>{};
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
      // 网络异常忽略，本地会话已清除。
    }
  }

  /// 调用一个 SYNO API。使用动态发现的 cgi 与 version，自动附加 _sid。
  Future<Map<String, dynamic>> call({
    required String api,
    required String method,
    Map<String, String?>? params,
    int? version,
    String? forceCgi,
    ResponseType? responseType,
  }) async {
    final s = _requireSession();
    final url = buildSynoUrl(
      host: s.host,
      cgi: forceCgi ?? _cgiFor(api),
      https: s.https,
      port: s.port,
      query: <String, String?>{
        'api': api,
        'version': '${version ?? _versionFor(api)}',
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
    return (await _getRaw(url)).requireData();
  }

  /// 与 call 相同，但不抛异常：用于「该 NAS 版本可能不支持」的可选能力探测。
  Future<SynoResponse?> tryCall({
    required String api,
    required String method,
    Map<String, String?>? params,
    int? version,
  }) async {
    try {
      final s = _requireSession();
      final url = buildSynoUrl(
        host: s.host,
        cgi: _cgiFor(api),
        https: s.https,
        port: s.port,
        query: <String, String?>{
          'api': api,
          'version': '${version ?? _versionFor(api)}',
          'method': method,
          '_sid': s.sid,
          ...?params,
        },
      );
      return await _getRaw(url);
    } catch (_) {
      return null;
    }
  }

  SynoSession _requireSession() {
    final s = _session;
    if (s == null) {
      throw SynoException(SynoErrorCode.sessionTimeout, '尚未登录或会话已失效');
    }
    return s;
  }

  /// 摄像机列表。带 streamInfo / camStm 才会返回直播流密钥 StmKey。
  Future<List<Map<String, dynamic>>> listCameras() async {
    final data = await call(
      api: SynoApi.camera,
      method: SynoMethod.list,
      params: <String, String?>{
        'privCamType': '3',
        'blIncludeDeletedCam': 'false',
        'streamInfo': 'true',
        'blPrivilege': 'false',
        'start': '0',
        'limit': '200',
        'basic': 'true',
        'blFromCamList': 'true',
        'camStm': '1',
      },
    );
    final raw = data['cameras'] ?? data['camList'] ?? data['list'];
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// 取指定摄像机的直播流路径（SS 返回的完整 URL 里含 StmKey）。
  Future<List<String>> getLiveViewPaths(List<int> cameraIds) async {
    if (cameraIds.isEmpty) return <String>[];
    final data = await call(
      api: SynoApi.camera,
      method: SynoMethod.getLiveViewPath,
      params: <String, String?>{'idList': cameraIds.join(',')},
    );
    final out = <String>[];
    void collect(dynamic v) {
      if (v is String && v.contains('://')) out.add(v);
      if (v is Map) v.values.forEach(collect);
      if (v is List) v.forEach(collect);
    }

    collect(data);
    return out;
  }

  /// 真实快照：返回 JPEG 字节。
  Future<List<int>> getSnapshot(int cameraId) async {
    final data = await call(
      api: SynoApi.camera,
      method: SynoMethod.getSnapshot,
      params: <String, String?>{'cameraId': '$cameraId', 'camStm': '1'},
      responseType: ResponseType.bytes,
    );
    final bytes = data['bytes'];
    if (bytes is List<int> && bytes.isNotEmpty) return bytes;
    throw SynoException(SynoErrorCode.unknown, '快照为空或格式异常');
  }

  /// 快照 URL（供 Image.network 轮询使用）。带 camStm 与防缓存时间戳。
  String snapshotUrl(int cameraId, {int? nonce}) {
    final s = _requireSession();
    return buildSynoUrl(
      host: s.host,
      cgi: _cgiFor(SynoApi.camera),
      https: s.https,
      port: s.port,
      query: <String, String?>{
        'api': SynoApi.camera,
        'version': '${_versionFor(SynoApi.camera)}',
        'method': SynoMethod.getSnapshot,
        'cameraId': '$cameraId',
        'camStm': '1',
        '_sid': s.sid,
        '_t': nonce == null ? null : '$nonce',
      },
    );
  }

  /// MJPEG 直播流 URL（真实 SS 流；StmKey 为空时不可用，UI 会明确提示）。
  String liveStreamUrl({required int cameraId, String? stmKey}) {
    final s = _requireSession();
    final api = _apiInfo.containsKey(SynoApi.videoStream)
        ? SynoApi.videoStream
        : SynoApi.videoStreamAlt;
    return buildSynoUrl(
      host: s.host,
      cgi: _cgiFor(api),
      https: s.https,
      port: s.port,
      query: <String, String?>{
        'api': api,
        'version': '${_versionFor(api)}',
        'method': SynoMethod.stream,
        'format': 'mjpeg',
        'cameraId': '$cameraId',
        'StmKey': (stmKey == null || stmKey.isEmpty) ? null : stmKey,
        '_sid': s.sid,
      },
    );
  }

  /// RTSP 直播路径（供系统播放器 / 后续原生播放器接入）。
  String rtspUrl(int cameraId) {
    final s = _requireSession();
    return 'rtsp://${s.host}:554/Sms=$cameraId.unicast';
  }

  /// 录像事件查询：SYNO.SurveillanceStation.Event / Query。
  /// 这是 SS 的录像片段列表（含锁定、时间、录制模式），也是通知页的真实数据源。
  Future<Map<String, dynamic>> queryEvents({
    int limit = 100,
    int offset = 0,
    int? fromTime,
    int? toTime,
    String? cameraIds,
    String? mode,
    int? locked,
  }) async {
    try {
      return await call(
        api: SynoApi.event,
        method: SynoMethod.queryEvents,
        params: <String, String?>{
          'limit': '$limit',
          'offset': '$offset',
          'fromTime': fromTime == null ? null : '$fromTime',
          'toTime': toTime == null ? null : '$toTime',
          'cameraIds': cameraIds,
          'mode': mode,
          'locked': locked == null ? null : '$locked',
        },
      );
    } on SynoException catch (e) {
      if (!SynoErrorCode.isUnsupported(e.code)) rethrow;
      // 少数 SS 版本把录像放在 Recording/List，做一次真实回退。
      return call(
        api: SynoApi.recording,
        method: SynoMethod.list,
        params: <String, String?>{
          'limit': '$limit',
          'offset': '$offset',
          'fromTime': fromTime == null ? null : '$fromTime',
          'toTime': toTime == null ? null : '$toTime',
          'cameraIds': cameraIds,
        },
      );
    }
  }

  /// SS 事件日志（通知）。不支持该 API 时返回 null，UI 显示真实空态而非假数据。
  Future<Map<String, dynamic>?> queryLog({int limit = 100}) async {
    final r = await tryCall(
      api: SynoApi.log,
      method: SynoMethod.list,
      params: <String, String?>{'limit': '$limit', 'offset': '0'},
    );
    return r?.success == true ? r?.data : null;
  }

  /// 锁定 / 解锁录像（先试 Recording，再回退 Event）。
  Future<void> setRecordingLocked(String id, bool locked) async {
    final method = locked ? SynoMethod.lock : SynoMethod.unlock;
    try {
      await call(
        api: SynoApi.recording,
        method: method,
        params: <String, String?>{'id': id},
      );
    } on SynoException catch (e) {
      if (!SynoErrorCode.isUnsupported(e.code)) rethrow;
      await call(
        api: SynoApi.event,
        method: method,
        params: <String, String?>{'id': id},
      );
    }
  }

  Future<void> deleteRecording(String id) async {
    try {
      await call(
        api: SynoApi.recording,
        method: SynoMethod.delete,
        params: <String, String?>{'id': id},
      );
    } on SynoException catch (e) {
      if (!SynoErrorCode.isUnsupported(e.code)) rethrow;
      await call(
        api: SynoApi.event,
        method: SynoMethod.delete,
        params: <String, String?>{'id': id},
      );
    }
  }

  /// 录像下载 / 播放 URL（带 _sid，可交给系统播放器打开）。
  String recordingDownloadUrl(String id) {
    final s = _requireSession();
    return buildSynoUrl(
      host: s.host,
      cgi: _cgiFor(SynoApi.recording),
      https: s.https,
      port: s.port,
      query: <String, String?>{
        'api': SynoApi.recording,
        'version': '${_versionFor(SynoApi.recording)}',
        'method': SynoMethod.download,
        'id': id,
        '_sid': s.sid,
      },
    );
  }

  ///  Surveillance Station 网页端地址（用于官方 API 未提供的高级配置）。
  String webUiUrl() {
    final s = _requireSession();
    return '${s.https ? 'https' : 'http'}://${s.host}:${s.port}';
  }

  Future<Map<String, dynamic>?> licenseInfo() async {
    final r = await tryCall(api: SynoApi.license, method: SynoMethod.getInfo);
    return r?.success == true ? r?.data : null;
  }

  Future<Map<String, dynamic>?> homeModeInfo() async {
    final r = await tryCall(api: SynoApi.homeMode, method: SynoMethod.getInfo);
    return r?.success == true ? r?.data : null;
  }

  Future<void> setHomeMode(bool enabled) async {
    await call(
      api: SynoApi.homeMode,
      method: SynoMethod.switchMode,
      params: <String, String?>{'on': enabled ? 'true' : 'false'},
    );
  }

  Future<void> ptz(String method, int cameraId,
      {Map<String, String?>? extra}) async {
    await call(
      api: SynoApi.ptz,
      method: method,
      params: <String, String?>{'cameraId': '$cameraId', ...?extra},
    );
  }

  Future<List<Map<String, dynamic>>> listPresets(int cameraId) async {
    final data = await call(
      api: SynoApi.ptz,
      method: SynoMethod.listPreset,
      params: <String, String?>{'cameraId': '$cameraId'},
    );
    final raw = data['presets'] ?? data['list'];
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> setCameraEnabled(List<int> ids, bool enabled) async {
    await call(
      api: SynoApi.camera,
      method: enabled ? SynoMethod.enable : SynoMethod.disable,
      params: <String, String?>{'idList': ids.join(',')},
    );
  }

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
      if (body is String) {
        try {
          return SynoResponse.fromBody(body);
        } on FormatException {
          throw SynoException(SynoErrorCode.unknown,
              '服务器返回的不是 JSON（HTTP ${r.statusCode}），请检查地址/端口/HTTPS 设置');
        }
      }
      if (body is Map) {
        return SynoResponse.fromJson(Map<String, dynamic>.from(body));
      }
      throw SynoException(SynoErrorCode.unknown,
          '无法解析服务器响应（HTTP ${r.statusCode}）');
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw SynoException(SynoErrorCode.unknown, '连接超时，请检查地址与网络');
      }
      if (e.type == DioExceptionType.badCertificate) {
        throw SynoException(SynoErrorCode.unknown,
            'HTTPS 证书不受信任。若 NAS 使用自签证书，请在「设置」开启「信任自签名证书」');
      }
      throw SynoException(SynoErrorCode.unknown, '网络错误：${e.message}');
    }
  }
}
