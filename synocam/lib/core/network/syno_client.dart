// Synology DSM / Surveillance Station Web API 客户端（真实链路，无演示数据）。
//
// 关键实证（SS Web API 官方文档 + 社区可运行实现）：
//  - JSON API（Camera/List、Event/Query）用 _sid query 即可；
//  - 二进制/流端点（GetSnapshot、VideoStreaming/Stream）走另一条鉴权，
//    必须同时带 Cookie: id=<sid>; did=<did>，否则 DSM 返回 HTTP 465 +
//    {"error":{"code":400},"success":false}（这正是「画面加载失败 465」的根因）；
//  - HTTP 465 还有第二种语义：SID 已过期时 DSM 门户返回「登录页 HTML」，
//    必须归类为「会话失效 → 重新登录」，不能误报成地址/HTTPS 配置错误；
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
        // 登录请求绝不能带上一轮的旧 SID Cookie：会话失效后重登时若带着
        // 废弃 Cookie，DSM 门户会直接回 465 登录页，表现为「登录没反应」。
        final c = _authenticating ? '' : _cookie;
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

  /// SYNO.API.Info 探测的真实结果（失败时保留原因，供设置页展示）。
  String _discoverDiagnostic = '尚未探测';
  String get discoverDiagnostic => _discoverDiagnostic;

  /// 最近一次登录的真实技术诊断：脱敏后的请求 URL、HTTP 状态、NAS 响应摘要、
  /// 错误码与耗时。登录页可展开并一键复制，用于定位外网 / QuickConnect /
  /// 证书 / 端口这类「本机无法复现」的连接问题。绝不含密码或验证码。
  String _loginDiagnostic = '尚未发起登录';
  String get loginDiagnostic => _loginDiagnostic;

  _SnapshotRecipe? _snapshotRecipe;

  /// 登录进行中标志：登录请求 / 能力发现期间不触发会话失效回调，
  /// 避免把一次新的登录误判成「旧会话过期」。
  bool _authenticating = false;

  /// 会话失效自动踢出的保护闸门：登录后的首次数据刷新、冷启动恢复期间由
  /// AppState 调 suppress()/release()，防止辅助端点偶发的 HTML/465 把刚登录
  /// 成功的用户踢回登录页。纯 Dart 类，逻辑可被核心自检直接覆盖。
  final SessionExpiryGuard sessionGuard = SessionExpiryGuard();

  /// 任何 API 链路识别出会话失效时回调（由 AppState 注册），覆盖
  /// JSON 错误码 106/119/150、HTTP 465 门户页、快照 / 录像下载等所有路径。
  void Function()? onSessionExpired;

  void _notifySessionExpired() {
    if (!sessionGuard.shouldExpire(
      detected: true,
      hasSession: _session != null,
      authenticating: _authenticating,
    )) {
      return;
    }
    onSessionExpired?.call();
  }

  /// 只清内存中的僵尸会话：不请求 NAS、不删持久化的设备令牌与连接信息，
  /// 以便重新登录时继续使用 did 免验证码并预填上次的连接参数。
  void clearSession() {
    _session = null;
    _apiInfo = <String, SynoApiInfoEntry>{};
    _snapshotRecipe = null;
  }

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
      _apiInfo[api]?.effectiveVersion() ?? SynoApi.defaultVersions[api] ?? 1;

  String _cgiFor(String api) => _apiInfo[api]?.cgi ?? SynoEndpoints.entryCgi;

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
      // 走统一的 _getRaw：HTTP 465 / 登录页 HTML 会被正确分类为会话失效，
      // 不再被静默吞掉，从而避免「僵尸会话」继续刷各页面。
      final resp = await _getRaw(url);
      final data = resp.data;
      if (resp.success && data != null) {
        _apiInfo = parseApiInfo(data);
        _discoverDiagnostic = 'SYNO.API.Info 返回 ${_apiInfo.length} 个接口';
      } else {
        _discoverDiagnostic =
            'SYNO.API.Info 返回 success=false（错误码 ${resp.error?.code ?? 0}）';
      }
    } catch (e) {
      _apiInfo = <String, SynoApiInfoEntry>{};
      _discoverDiagnostic = 'SYNO.API.Info 读取失败：$e';
    }
  }

  /// 需要认证的会话探针：恢复旧 SID 后先打一次 Camera/List，让 HTTP 465 /
  /// 登录页 HTML 在刷新各页面之前就被识别为「会话失效」，直接回登录页。
  Future<void> validateSession() async {
    await call(
      api: SynoApi.camera,
      method: SynoMethod.list,
      params: <String, String?>{
        'privCamType': '3',
        'streamInfo': 'true',
        'camStm': '1',
        'start': '0',
        'limit': '1',
        'basic': 'true',
      },
    );
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

    _authenticating = true;
    final sw = Stopwatch()..start();
    var httpStatus = 0;
    dynamic rawBody;
    try {
      final resp = await _getRaw(url, capture: (int status, dynamic body) {
        httpStatus = status;
        rawBody = body;
      });
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
      _snapshotRecipe = null;
      _loginDiagnostic = _formatLoginDiagnostic(
        url: url,
        status: httpStatus,
        body: rawBody,
        elapsed: sw.elapsedMilliseconds,
        note: '登录成功，已取得 SID',
      );
      try {
        await discoverApis();
      } catch (e) {
        _discoverDiagnostic = 'SYNO.API.Info 读取失败：$e（已按默认版本继续）';
      }
      return _session!;
    } on SynoException catch (e) {
      _loginDiagnostic = _formatLoginDiagnostic(
        url: url,
        status: httpStatus,
        body: rawBody,
        elapsed: sw.elapsedMilliseconds,
        note: 'DSM 返回错误码 ${e.code}：${e.message}',
      );
      rethrow;
    } catch (e) {
      _loginDiagnostic = _formatLoginDiagnostic(
        url: url,
        status: httpStatus,
        body: rawBody,
        elapsed: sw.elapsedMilliseconds,
        note: '请求异常：$e',
      );
      rethrow;
    } finally {
      _authenticating = false;
    }
  }

  String _formatLoginDiagnostic({
    required String url,
    required int status,
    required dynamic body,
    required int elapsed,
    required String note,
  }) {
    final text = body == null
        ? ''
        : body.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    final snippet = text.isEmpty
        ? '(空响应)'
        : (text.length > 220 ? '${text.substring(0, 220)}…' : text);
    return <String>[
      note,
      '耗时 ${elapsed}ms · HTTP ${status > 0 ? status : '未收到响应'}',
      '请求：${sanitizeApiUrl(url)}',
      'NAS 响应：$snippet',
    ].join('\n');
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
      final sessionError = _classifyBytes(r.statusCode ?? 0, r.data);
      if (sessionError != null) throw sessionError;
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
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
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
      _SnapshotRecipe(
          v,
          <String, String>{
            'cameraId': '$cameraId',
            'id': '$cameraId',
            'camStm': '1',
            'profileType': '1',
          },
          'v$v 全参数'),
      _SnapshotRecipe(
          1,
          <String, String>{
            'cameraId': '$cameraId',
            'camStm': '1',
          },
          'v1 cameraId'),
      _SnapshotRecipe(
          8,
          <String, String>{
            'cameraId': '$cameraId',
            'camStm': '1',
          },
          'v8 cameraId'),
      _SnapshotRecipe(
          9,
          <String, String>{
            'id': '$cameraId',
            'profileType': '1',
          },
          'v9 id/profileType'),
    ];
    final cached = _snapshotRecipe;
    if (cached != null) {
      all.removeWhere((r) => r.label == cached.label);
      all.insert(0, cached);
    }
    return all;
  }

  String _snapshotUrl(int cameraId, int version, Map<String, String> extra) =>
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
        // 会话失效（HTTP 465 / 登录页 HTML / JSON 106/119/150）立即上抛，
        // 不再逐个参数组合重试，也不会把整段 HTML 当作画面错误展示。
        final sessionError = _classifyBytes(status, bytes);
        if (sessionError != null) {
          _mediaDiagnostic = '快照失败：登录会话已过期（HTTP $status）';
          throw sessionError;
        }
        notes.add('${r.label}: HTTP $status ${_bodyHint(bytes)}');
      } on DioException catch (e) {
        notes.add(
            '${r.label}: HTTP ${e.response?.statusCode ?? '?'} ${e.type.name}');
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
      r?.params ?? <String, String>{'cameraId': '$cameraId', 'camStm': '1'},
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
    return text
        .replaceAll(RegExp(r'\s+'), ' ')
        .substring(0, text.length > 60 ? 60 : text.length);
  }

  // ── MJPEG 实时流（仅实时预览，绝不用于录像回放）────────────────────
  //
  // 重要实证：SS 的 VideoStreaming/Stream(format=mjpeg) 是「实时流」接口，
  // 不接受 startTime/endTime 做历史回放。旧实现给它拼上 startTime/endTime
  // 当「回放流」用，NAS 会直接忽略这些参数返回实时画面——这正是用户反复
  // 反馈「回放选中的时间，却依旧播放实时画面」的根因。因此这里彻底移除
  // 时间参数，从协议层杜绝把实时流误当回放；历史回放改走
  // 官方 Recording/Download 取真实录像文件。
  String liveStreamUrl({required Camera camera}) {
    final s = _requireSession();
    if (camera.livePath != null && camera.livePath!.isNotEmpty) {
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
      },
    );
  }

  String rtspUrl(int cameraId) {
    final s = _requireSession();
    return 'rtsp://${s.host}:554/Sms=$cameraId.unicast';
  }

  // ── 录像片段下载（App 内回放用）─────────────────────────────────────
  //
  // 依据 Synology《Surveillance Station Web API》2.3.11：
  //   • List     (version>=6)  cameraIds / fromTime / toTime → 真实录像 id
  //   • Download (version>=6)  id + offsetTimeMs + playTimeMs → MP4 文件数据
  //   • Stream   (version>=6)  recordingId → 206 video/mp4（支持 Range）
  // 事件 id 与录像 id 同源（2.3.11.15 CheckEventValid 用 eventId 核对录像），
  // 但个别 SS 版本会分表，故额外以 Recording/List 兜底取真实录像 id。
  //
  // 上一版臆造了「Recording/GetSnapshot 按时刻历史帧」和
  // 「cameraId+startTime+stopTime 下载」两种配方——官方均不存在，
  // 导致所有回放直接失败。此处全部改为官方支持的调用。

  /// Download / Stream 候选版本：官方标注 6 and onward，旧 SS 用 4/5，
  /// 故按 6 → 探测版本 → 9 → 5 → 4 依次尝试（去重保序）。
  List<int> _recordingVersions() {
    final out = <int>[6];
    for (final v in <int>[_versionFor(SynoApi.recording), 9, 5, 4]) {
      if (!out.contains(v)) out.add(v);
    }
    return out;
  }

  /// 用官方 Recording/List 查覆盖该时间窗的真实录像 id（兜底候选）。
  /// 响应 recordings[] 每项含 id；接口不支持时静默返回空列表。
  Future<List<String>> listRecordingIds(
      int cameraId, int fromSec, int toSec) async {
    for (final v in <int>[6, 4]) {
      final ids = <String>[];
      try {
        final data = await call(
          api: SynoApi.recording,
          method: SynoMethod.list,
          version: v,
          params: <String, String?>{
            'cameraIds': '$cameraId',
            'fromTime': '${fromSec - 300}',
            'toTime': '${toSec + 300}',
            'offset': '0',
            'limit': '60',
          },
        );
        final raw = data['recordings'] ?? data['events'] ?? data['list'];
        if (raw is List) {
          for (final e in raw) {
            if (e is Map) {
              final id = e['id'] ?? e['eventId'] ?? e['recordingId'];
              if (id != null && '$id'.isNotEmpty) ids.add('$id');
            }
          }
        }
        if (ids.isNotEmpty) return ids;
      } catch (_) {
        // 该版本不支持 List 或权限不足，继续尝试下一版本。
      }
    }
    return <String>[];
  }

  /// 下载「从选中时刻开始」的真实录像 → App 内播放器。
  ///
  /// [at] 为时间轴上选中的绝对时刻。优先用官方
  /// id + offsetTimeMs + playTimeMs 让 NAS 直接从该时刻切出 MP4；
  /// 若 NAS 版本不支持，则下载整段 MP4，由回放页按 seek 偏移定位。
  Future<RecordingFile> downloadRecording(Recording r, {DateTime? at}) async {
    final win = recordingWindowFor(r, at ?? r.startTime);
    final offsetMs = win.seekSeconds * 1000;
    final span = (win.to - win.from) > 0 ? (win.to - win.from) : 60;
    final playMs = span * 1000;
    final notes = <String>[];
    final versions = _recordingVersions();

    // 对单个录像 id 依次尝试官方 Download / Stream 配方。
    Future<RecordingFile?> attempt(String id) async {
      for (final v in versions) {
        final recipes = <Map<String, String>>[
          <String, String>{
            'id': id,
            'offsetTimeMs': '$offsetMs',
            'playTimeMs': '$playMs',
          },
          <String, String>{'id': id},
          <String, String>{'idList': id},
        ];
        for (final params in recipes) {
          final byOffset = params.containsKey('offsetTimeMs');
          final hit = await _tryRecordingBytes(
              _recordingUrl(params, version: v), 'Download v$v', notes);
          if (hit == null) continue;
          _mediaDiagnostic = '录像下载成功：id=$id v$v '
              '${params.keys.join(',')}（${hit.length} 字节）';
          return RecordingFile(
            bytes: hit,
            extension: MediaBytes.extensionFor(hit),
            source: 'Download v$v ${params.keys.join(',')}',
            contentType: 'video/mp4',
            startsAt: byOffset
                ? DateTime.fromMillisecondsSinceEpoch(win.from * 1000)
                : r.startTime,
          );
        }
      }
      // Download 全失败 → 官方 Recording/Stream（206 video/mp4）。
      for (final v in versions) {
        final hit = await _tryRecordingBytes(
          _recordingUrl(<String, String>{'recordingId': id},
              version: v, method: SynoMethod.stream),
          'Stream v$v',
          notes,
        );
        if (hit == null) continue;
        _mediaDiagnostic = '录像流成功：recordingId=$id v$v（${hit.length} 字节）';
        return RecordingFile(
          bytes: hit,
          extension: MediaBytes.extensionFor(hit),
          source: 'Stream v$v recordingId',
          contentType: 'video/mp4',
          startsAt: r.startTime,
        );
      }
      return null;
    }

    // 事件 ID 与录像 ID 同源（官方 2.3.11.15 CheckEventValid 用 eventId
    // 核对录像），先直接用它，避免每次回放都多发一次可能超时的 List。
    final first = await attempt(r.id);
    if (first != null) return first;

    // 仅当事件 ID 全部失败，才查真实录像列表（个别 SS 版本分表）。
    final listed = await listRecordingIds(r.cameraId, win.from, win.to);
    var tried = 1;
    for (final id in listed.where((String x) => x != r.id).take(8)) {
      tried++;
      final hit = await attempt(id);
      if (hit != null) return hit;
    }
    _mediaDiagnostic = '录像下载全部失败 → ${notes.take(6).join(' | ')}';
    throw SynoException(
        SynoErrorCode.unknown,
        'NAS 未返回可用录像文件（已尝试 $tried 个录像 ID / '
        '${versions.length} 个 API 版本）。${notes.take(3).join('；')}');
  }

  /// 请求媒体字节并校验不是 JSON 错误 / HTML 登录页。成功返回字节，
  /// 失败把真实响应记入 [notes] 并返回 null；会话失效时直接抛出。
  Future<List<int>?> _tryRecordingBytes(
      String url, String tag, List<String> notes) async {
    try {
      final resp = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 25),
        ),
      );
      final bytes = resp.data;
      final status = resp.statusCode ?? 0;
      if (status >= 200 &&
          status < 300 &&
          bytes != null &&
          !MediaBytes.looksLikeJsonError(bytes)) {
        return bytes;
      }
      final sessionError = _classifyBytes(status, bytes);
      if (sessionError != null) {
        _mediaDiagnostic = '录像请求失败：登录会话已过期（HTTP $status）';
        throw sessionError;
      }
      notes.add('$tag: HTTP $status ${_bodyHint(bytes)}');
    } on DioException catch (e) {
      notes.add('$tag: HTTP ${e.response?.statusCode ?? '?'} ${e.type.name}');
    }
    return null;
  }

  String _recordingUrl(
    Map<String, String> params, {
    required int version,
    String? method,
  }) =>
      buildSynoUrl(
        host: _requireSession().host,
        cgi: _cgiFor(SynoApi.recording),
        https: _session!.https,
        port: _session!.port,
        query: <String, String?>{
          'api': SynoApi.recording,
          'version': '$version',
          'method': method ?? SynoMethod.download,
          '_sid': _session!.sid,
          ...params,
        },
      );

  /// 仅用于「复制链接」这类用户主动操作，不再作为点击事件的默认行为。
  String recordingDownloadUrl(String id) =>
      _recordingUrl(<String, String>{'id': id},
          version: _versionFor(SynoApi.recording));

  // ── 实时 HLS 视频流 / 独立音频流 ────────────────────────────────────
  //
  // 群晖 SS 公开实时流只有 MJPEG（逐帧 JPEG 软解码，易卡顿、无音频）。
  // 实证另有两条 CGI：videoStreaming.cgi（VideoStream / format=hls）与
  // audioStreaming.cgi（AudioStream / version=2）。视频流不含音轨，音频
  // 必须单独播放。两者均为「探测成功才启用」，失败自动回退 MJPEG。

  /// 播放前需先 Open，否则视频流在闲置后处于关闭状态。
  Future<bool> openHlsStream(int cameraId) async {
    try {
      final r = await _getRaw(_streamingCgiUrl(
        SynoEndpoints.videoStreamingCgi,
        <String, String?>{
          'api': SynoApi.videoStreamHls,
          'version': '1',
          'method': SynoMethod.open,
          'cameraId': '$cameraId',
          'format': 'hls',
          '_sid': _requireSession().sid,
        },
      ));
      return r.success;
    } catch (_) {
      return false;
    }
  }

  String hlsStreamUrl(int cameraId) => _streamingCgiUrl(
        SynoEndpoints.videoStreamingCgi,
        <String, String?>{
          'api': SynoApi.videoStreamHls,
          'version': '1',
          'method': SynoMethod.stream,
          'cameraId': '$cameraId',
          'format': 'hls',
          '_sid': _requireSession().sid,
        },
      );

  String audioStreamUrl(int cameraId) => _streamingCgiUrl(
        SynoEndpoints.audioStreamingCgi,
        <String, String?>{
          'api': SynoApi.audioStream,
          'version': '2',
          'method': SynoMethod.stream,
          'cameraId': '$cameraId',
          '_sid': _requireSession().sid,
        },
      );

  String _streamingCgiUrl(String cgi, Map<String, String?> query) {
    final s = _requireSession();
    return buildSynoUrl(
      host: s.host,
      cgi: cgi,
      https: s.https,
      port: s.port,
      query: query,
    );
  }

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
          api: SynoApi.recording,
          method: method,
          params: <String, String?>{'id': id});
    } on SynoException catch (e) {
      if (!SynoErrorCode.isUnsupported(e.code)) rethrow;
      await call(
          api: SynoApi.event,
          method: method,
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
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
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

  /// 把「非 JSON 的 HTTP 响应」分类，并在判定为会话失效时通知全局。
  SynoException _classified(int status, String body) {
    final e = classifyHttpResponse(status, body);
    if (e.needsReLogin) _notifySessionExpired();
    return e;
  }

  /// 二进制端点（快照 / 录像下载）的会话失效判定：HTTP 465、登录页 HTML、
  /// 或 JSON 里的 106/119/150 错误码都归为「需要重新登录」。
  SynoException? _classifyBytes(int status, List<int>? bytes) {
    final text = bytes == null || bytes.isEmpty
        ? ''
        : latin1.decode(bytes.take(300).toList(), allowInvalid: true);
    final e = classifyHttpResponse(status, text);
    if (e.needsReLogin) {
      _notifySessionExpired();
      return e;
    }
    final m = RegExp(r'"code"\s*:\s*(\d+)').firstMatch(text);
    if (m != null) {
      final code = int.tryParse(m.group(1)!) ?? 0;
      final se = SynoException.fromCode(code);
      if (se.needsReLogin) {
        _notifySessionExpired();
        return se;
      }
    }
    return null;
  }

  SynoResponse _parseBody(dynamic body, int status) {
    if (body is String) {
      try {
        return SynoResponse.fromBody(body);
      } on FormatException {
        throw _classified(status, body);
      }
    }
    if (body is Map) {
      return SynoResponse.fromJson(Map<String, dynamic>.from(body));
    }
    throw _classified(status, body == null ? '' : body.toString());
  }

  Future<SynoResponse> _getRaw(String url,
      {void Function(int status, dynamic body)? capture}) async {
    try {
      final r = await _dio.get<dynamic>(url);
      final status = r.statusCode ?? 0;
      capture?.call(status, r.data);
      final resp = _parseBody(r.data, status);
      // JSON 形式的会话失效（106/119/150）同样要触发统一恢复闭环。
      final code = resp.error?.code;
      if (code != null && SynoException.fromCode(code).needsReLogin) {
        _notifySessionExpired();
      }
      return resp;
    } on DioException catch (e) {
      capture?.call(e.response?.statusCode ?? 0, e.response?.data);
      final d = e.response?.data;
      final raw =
          d == null ? '' : d.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      final detail = raw.isEmpty
          ? ''
          : ' · NAS 响应：${raw.length > 120 ? '${raw.substring(0, 120)}…' : raw}';
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw SynoException(SynoErrorCode.unknown, '连接超时，请检查地址与网络');
      }
      if (e.type == DioExceptionType.badCertificate) {
        throw SynoException(SynoErrorCode.unknown,
            'HTTPS 证书不受信任。若 NAS 使用自签证书，请开启「信任自签名 HTTPS 证书」');
      }
      throw SynoException(SynoErrorCode.unknown, '网络错误：${e.message}$detail');
    }
  }
}

class _SnapshotRecipe {
  const _SnapshotRecipe(this.version, this.params, this.label);
  final int version;
  final Map<String, String> params;
  final String label;
}
