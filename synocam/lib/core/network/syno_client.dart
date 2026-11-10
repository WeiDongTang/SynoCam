// Synology DSM / Surveillance Station Web API 客户端（真实链路，无演示数据）。
//
// 关键实证（SS Web API 官方文档 + 社区可运行实现）：
//  - JSON API（Camera/List、Event/Query）用 _sid query 即可；
//  - 二进制/流端点（GetSnapshot、VideoStreaming/Stream）走另一条鉴权，
//    必须同时带 Cookie: id=<sid>; did=<did>，否则 DSM 返回 HTTP 465 +
//    {"error":{"code":400},"success":false}（这正是「画面加载失败 465」的根因）；
//  - GetSnapshot 参数随版本变化：v1/v8 用 cameraId+camStm，v9 用 id+profileType，
//    故做多组合回退，并缓存成功组合；
//  - StmKey 来自 Camera/GetLiveViewPath 返回的完整 URL，不是 Camera/List 的普通字段。
//
// 所有失败都抛出携带诊断的 SynoException，绝不静默回退到假数据。
import 'dart:convert';

import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../../data/models/camera.dart';
import '../../data/models/media.dart';
import '../../data/models/syno_session.dart';
import 'syno_api.dart';

class SynoClient {
  SynoClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: AppConfig.connectTimeout,
              receiveTimeout: AppConfig.receiveTimeout,
              // 465 等 DSM 自定义 HTTP 码也要读 body 才能给出可读诊断。
              validateStatus: (s) => s != null && s < 600,
            )) {
    // 统一为所有请求注入会话 Cookie 与 UA：流端点依赖 Cookie，JSON API 也兼容。
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (RequestOptions o, RequestInterceptorHandler h) {
        final c = _cookie;
        if (c.isNotEmpty) o.headers['Cookie'] = c;
        o.headers.putIfAbsent('User-Agent', () => 'SynoCam/1.0');
        h.next(o);
      },
    ));
  }

  final Dio _dio;
  SynoSession? _session;
  Map<String, SynoApiInfoEntry> _apiInfo = <String, SynoApiInfoEntry>{};

  /// 最近一次快照/流的诊断（供设置页「连接诊断」展示）。
  String _mediaDiagnostic = '尚未请求';
  String get mediaDiagnostic => _mediaDiagnostic;

  _SnapshotRecipe? _snapshotRecipe;

  SynoSession? get session => _session;
  bool get isLoggedIn => _session != null;
  Map<String, SynoApiInfoEntry> get apiInfo => _apiInfo;

  /// SS 流端点要求的会话 Cookie（构造逻辑集中在 SynoSession，便于自检覆盖）。
  String get _cookie => _session?.cookieHeader ?? '';

  /// 供 MJPEG 流客户端复用（dart:io HttpClient 不与 Dio 共享拦截器）。
  String get cookieHeader => _cookie;

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

  /// 查询 NAS 实际支持的 API 与版本。
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
      _apiInfo = <String, SynoApiInfoEntry>{};
    }
  }

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
    _snapshotRecipe = null;
    await discoverApis();
    return _session!;
  }

  Future<void> logout() async {
    final s = _session;
    _session = null;
    _apiInfo = <String, SynoApiInfoEntry>{};
    _snapshotRecipe = null;
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
      return <String, dynamic>{'bytes': r.data, 'status': r.statusCode};
    }
    return (await _getRaw(url)).requireData();
  }

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

  // ── 摄像机 ────────────────────────────────────────────────────────────

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

  /// GetLiveViewPath：返回 cameraId → 完整 MJPEG 流 URL（含 StmKey）。
  /// SS 各版本把路径放在 data 的不同层级，故递归收集并按 cameraId 配对。
  Future<Map<int, String>> getLiveViewPaths(List<int> cameraIds) async {
    if (cameraIds.isEmpty) return <int, String>{};
    try {
      final data = await call(
        api: SynoApi.camera,
        method: SynoMethod.getLiveViewPath,
        version: 9,
        params: <String, String?>{'idList': cameraIds.join(',')},
      );
      return _pairPaths(data, cameraIds);
    } on SynoException catch (_) {
      // 部分 SS 版本把该方法挂在较低版本，再试一次。
      try {
        final data = await call(
          api: SynoApi.camera,
          method: SynoMethod.getLiveViewPath,
          version: 1,
          params: <String, String?>{'idList': cameraIds.join(',')},
        );
        return _pairPaths(data, cameraIds);
      } catch (_) {
        return <int, String>{};
      }
    }
  }

  Map<int, String> _pairPaths(Map<String, dynamic> data, List<int> ids) {
    final found = <String>[];
    void collect(dynamic v) {
      if (v is String && v.contains('method=Stream')) found.add(v);
      if (v is Map) v.values.forEach(collect);
      if (v is List) v.forEach(collect);
    }

    collect(data);
    final out = <int, String>{};
    for (final path in found) {
      final m = RegExp(r'cameraId[=":\s]*"?(\d+)', caseSensitive: false)
          .firstMatch(path);
      if (m != null) {
        final id = int.tryParse(m.group(1)!) ?? 0;
        if (ids.contains(id)) out[id] = path;
      }
    }
    // URL 里没有 cameraId 时，按请求顺序配对。
    if (out.isEmpty && found.isNotEmpty) {
      for (var i = 0; i < ids.length && i < found.length; i++) {
        out[ids[i]] = found[i];
      }
    }
    return out;
  }

  /// 把 SS 返回的流 URL 改写到当前会话的 host/port/scheme。
  /// NAS 常返回内网 IP，用户从外网（DDNS/QuickConnect）访问时必须重写。
  String absolutizeStreamUrl(String raw) {
    final s = _session;
    if (s == null) return raw;
    final uri = Uri.tryParse(raw);
    if (uri == null) return raw;
    if (!uri.hasScheme) {
      return buildSynoUrl(
        host: s.host,
        cgi: uri.path.isEmpty ? SynoEndpoints.entryCgi : uri.path,
        https: s.https,
        port: s.port,
        query: uri.queryParameters,
      );
    }
    return uri
        .replace(
          scheme: s.https ? 'https' : 'http',
          host: s.host,
          port: s.port,
        )
        .toString();
  }

  // ── 快照（真实 JPEG 字节，多重回退）─────────────────────────────────

  List<_SnapshotRecipe> _snapshotRecipes(int cameraId) {
    final v = _versionFor(SynoApi.camera);
    final all = <_SnapshotRecipe>[
      _SnapshotRecipe(v, <String, String>{
        'cameraId': '$cameraId',
        'id': '$cameraId',
        'camStm': '1',
        'profileType': '1',
      }, 'v$v 全参数'),
      _SnapshotRecipe(1, <String, String>{
        'cameraId': '$cameraId',
        'camStm': '1',
      }, 'v1 cameraId'),
      _SnapshotRecipe(8, <String, String>{
        'cameraId': '$cameraId',
        'camStm': '1',
      }, 'v8 cameraId'),
      _SnapshotRecipe(9, <String, String>{
        'id': '$cameraId',
        'profileType': '1',
      }, 'v9 id/profileType'),
    ];
    final cached = _snapshotRecipe;
    if (cached != null) {
      all.removeWhere((r) => r.label == cached.label);
      all.insert(0, cached);
    }
    return all;
  }

  String _snapshotUrl(
          int cameraId, int version, Map<String, String> extra) =>
      buildSynoUrl(
        host: _requireSession().host,
        cgi: _cgiFor(SynoApi.camera),
        https: _session!.https,
        port: _session!.port,
        query: <String, String?>{
          'api': SynoApi.camera,
          'version': '$version',
          'method': SynoMethod.getSnapshot,
          '_sid': _session!.sid,
          '_t': '${DateTime.now().millisecondsSinceEpoch}',
          ...extra,
        },
      );

  /// 真实快照：返回 JPEG/PNG 字节。带 Cookie、多版本/多参数回退、成功组合缓存。
  Future<List<int>> getSnapshot(int cameraId) async {
    final notes = <String>[];
    for (final r in _snapshotRecipes(cameraId)) {
      final url = _snapshotUrl(cameraId, r.version, r.params);
      try {
        final resp = await _dio.get<List<int>>(
          url,
          options: Options(
            responseType: ResponseType.bytes,
            headers: <String, dynamic>{
              'Accept': 'image/jpeg,image/png,image/*,*/*',
            },
          ),
        );
        final bytes = resp.data;
        final status = resp.statusCode ?? 0;
        if (status == 200 && bytes != null && MediaBytes.isImage(bytes)) {
          _snapshotRecipe = r;
          _mediaDiagnostic = '快照成功：${r.label}（${bytes.length} 字节）';
          return bytes;
        }
        notes.add('${r.label}: HTTP $status ${_bodyHint(bytes)}');
      } on DioException catch (e) {
        notes.add('${r.label}: HTTP ${e.response?.statusCode ?? '?'} ${e.type.name}');
      }
    }
    _mediaDiagnostic = '快照全部失败 → ${notes.join(' | ')}';
    throw SynoException(SynoErrorCode.unknown,
        '快照获取失败（已尝试 ${notes.length} 种参数组合）：${notes.take(2).join('；')}');
  }

  /// 快照 URL（仅用于复制链接/诊断；实际取图统一走 getSnapshot 的 Dio 链路）。
  String snapshotUrl(int cameraId, {int? nonce}) {
    final r = _snapshotRecipe;
    return _snapshotUrl(
      cameraId,
      r?.version ?? _versionFor(SynoApi.camera),
      r?.params ??
          <String, String>{'cameraId': '$cameraId', 'camStm': '1'},
    );
  }

  // 图片/录像字节识别统一走 MediaBytes（纯 Dart，可被核心自检覆盖）。

  String _bodyHint(List<int>? b) {
    if (b == null || b.isEmpty) return '空响应';
    final text = latin1.decode(b.take(300).toList(), allowInvalid: true);
    final m = RegExp(r'"code"\s*:\s*(\d+)').firstMatch(text);
    if (m != null) {
      return 'DSM 错误码 ${m.group(1)}（${SynoErrorCode.describe(int.parse(m.group(1)!))}）';
    }
    return text.replaceAll(RegExp(r'\s+'), ' ').substring(
        0, text.length > 60 ? 60 : text.length);
  }

  // ── MJPEG 直播 / 回放流 ──────────────────────────────────────────────

  /// 优先返回 NAS 给出的原始流路径；否则按官方格式拼装。
  String liveStreamUrl({
    required Camera camera,
    int? startTime,
    int? endTime,
  }) {
    final s = _requireSession();
    if (startTime == null &&
        camera.livePath != null &&
        camera.livePath!.isNotEmpty) {
      return absolutizeStreamUrl(camera.livePath!);
    }
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
        'version': '1',
        'method': SynoMethod.stream,
        'format': 'mjpeg',
        'cameraId': '${camera.id}',
        'StmKey': (camera.stmKey == null || camera.stmKey!.isEmpty)
            ? null
            : camera.stmKey,
        '_sid': s.sid,
        'startTime': startTime == null ? null : '$startTime',
        'endTime': endTime == null ? null : '$endTime',
      },
    );
  }

  String rtspUrl(int cameraId) {
    final s = _requireSession();
    return 'rtsp://${s.host}:554/Sms=$cameraId.unicast';
  }

  // ── 录像片段下载（App 内回放用）─────────────────────────────────────

  /// 下载真实录像片段。SS 各版本的 Download 参数不一致，做多重回退并
  /// 校验响应确实是媒体文件（而不是 {"error":{"code":400}} 这样的 JSON）。
  Future<RecordingFile> downloadRecording(Recording r) async {
    final from = r.startTime.millisecondsSinceEpoch ~/ 1000;
    final to = from + (r.durationSeconds > 0 ? r.durationSeconds : 60);
    final recipes = <Map<String, String>>[
      <String, String>{
        'id': r.id,
        'cameraId': '${r.cameraId}',
        'startTime': '$from',
        'stopTime': '$to',
      },
      <String, String>{'idList': r.id},
      <String, String>{
        'recordingId': r.id,
        'cameraId': '${r.cameraId}',
        'startTime': '$from',
        'endTime': '$to',
      },
      <String, String>{'id': r.id},
    ];
    final notes = <String>[];
    for (final params in recipes) {
      final url = _recordingUrl(params);
      try {
        final resp = await _dio.get<List<int>>(
          url,
          options: Options(
            responseType: ResponseType.bytes,
            receiveTimeout: const Duration(seconds: 90),
          ),
        );
        final bytes = resp.data;
        final status = resp.statusCode ?? 0;
        if (status == 200 && bytes != null && !MediaBytes.looksLikeJsonError(bytes)) {
          _mediaDiagnostic = '录像下载成功：${params.keys.join(',')}'
              '（${bytes.length} 字节）';
          return RecordingFile(
            bytes: bytes,
            extension: MediaBytes.extensionFor(bytes),
            source: params.keys.join(','),
            contentType:
                '${resp.headers.value('content-type') ?? 'application/octet-stream'}',
          );
        }
        notes.add('HTTP $status ${_bodyHint(bytes)}');
      } on DioException catch (e) {
        notes.add('HTTP ${e.response?.statusCode ?? '?'} ${e.type.name}');
      }
    }
    _mediaDiagnostic = '录像下载全部失败 → ${notes.join(' | ')}';
    throw SynoException(SynoErrorCode.unknown,
        '录像片段获取失败：${notes.take(2).join('；')}');
  }

  String _recordingUrl(Map<String, String> params) => buildSynoUrl(
        host: _requireSession().host,
        cgi: _cgiFor(SynoApi.recording),
        https: _session!.https,
        port: _session!.port,
        query: <String, String?>{
          'api': SynoApi.recording,
          'version': '${_versionFor(SynoApi.recording)}',
          'method': SynoMethod.download,
          '_sid': _session!.sid,
          ...params,
        },
      );

  /// 仅用于「复制链接」这类用户主动操作，不再作为点击事件的默认行为。
  String recordingDownloadUrl(String id) => _recordingUrl(<String, String>{
        'id': id,
      });

  // ── 录像事件 / 日志 / 其它真实 API ──────────────────────────────────

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

  Future<Map<String, dynamic>?> queryLog({int limit = 100}) async {
    final r = await tryCall(
      api: SynoApi.log,
      method: SynoMethod.list,
      params: <String, String?>{'limit': '$limit', 'offset': '0'},
    );
    return r?.success == true ? r?.data : null;
  }

  Future<void> setRecordingLocked(String id, bool locked) async {
    final method = locked ? SynoMethod.lock : SynoMethod.unlock;
    try {
      await call(
          api: SynoApi.recording, method: method,
          params: <String, String?>{'id': id});
    } on SynoException catch (e) {
      if (!SynoErrorCode.isUnsupported(e.code)) rethrow;
      await call(
          api: SynoApi.event, method: method,
          params: <String, String?>{'id': id});
    }
  }

  Future<void> deleteRecording(String id) async {
    try {
      await call(
          api: SynoApi.recording,
          method: SynoMethod.delete,
          params: <String, String?>{'id': id});
    } on SynoException catch (e) {
      if (!SynoErrorCode.isUnsupported(e.code)) rethrow;
      await call(
          api: SynoApi.event,
          method: SynoMethod.delete,
          params: <String, String?>{'id': id});
    }
  }

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

  /// 主动诊断：跑一次真实快照并把结果写入 mediaDiagnostic。
  Future<String> testSnapshot(int cameraId) async {
    try {
      await getSnapshot(cameraId);
    } catch (_) {
      // 诊断信息已写入 _mediaDiagnostic。
    }
    return _mediaDiagnostic;
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

class _SnapshotRecipe {
  const _SnapshotRecipe(this.version, this.params, this.label);
  final int version;
  final Map<String, String> params;
  final String label;
}
