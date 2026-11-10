// ignore_for_file: avoid_print, avoid_relative_lib_imports
//
// 说明：本脚本刻意使用相对导入以保持「零外部依赖、可直接 dart run」，
// 并用 print 输出断言结果（CLI 工具的正常行为），故抑制这两类 lint。
// 核心协议层自检脚本（纯 Dart，零外部依赖）：
//   dart run tool/verify_core.dart
// 用于在无法运行 flutter build 的环境（如无 Xcode/SDK 的 CI 前置阶段）里，
// 真实执行 URL 构造 / 响应解析 / 错误码 / 模型映射 / 功能开关的逻辑断言。
import '../lib/core/config/app_config.dart';
import '../lib/core/config/feature_flags.dart';
import '../lib/core/network/mjpeg_stream.dart';
import '../lib/core/network/syno_api.dart';
import '../lib/core/storage/secure_store.dart';
import '../lib/core/utils/time_sync.dart';
import '../lib/data/models/camera.dart';
import '../lib/data/models/media.dart';
import '../lib/data/models/syno_session.dart';

int _checks = 0;

void check(bool cond, String label) {
  _checks++;
  if (!cond) throw StateError('✗ 断言失败: $label');
  print('  ✓ $label');
}

Future<void> main() async {
  print('── buildSynoUrl ──');
  final loginUrl = buildSynoUrl(
    host: '192.168.1.10',
    cgi: SynoEndpoints.authCgi,
    https: false,
    query: <String, String?>{
      'api': SynoApi.auth,
      'version': '6',
      'method': 'login',
      'account': 'admin',
      'passwd': 'p@ss',
      'session': 'SurveillanceStation',
      'format': 'sid',
      'otp_code': null,
    },
  );
  check(loginUrl.startsWith('http://192.168.1.10:5000/webapi/auth.cgi'),
      'HTTP 默认端口 5000');
  check(loginUrl.contains('api=SYNO.API.Auth'), 'api 参数');
  check(!loginUrl.contains('otp_code'), 'null 参数被剔除');
  check(loginUrl.contains('passwd=p%40ss'), '特殊字符被正确编码');

  final httpsUrl = buildSynoUrl(
    host: 'https://nas.example.com',
    cgi: SynoEndpoints.entryCgi,
    https: false,
    query: <String, String?>{'api': SynoApi.camera},
  );
  check(httpsUrl.startsWith('https://nas.example.com:5001/'),
      'host 自带 https scheme 时自动切 5001');

  final entryUrl = buildSynoUrl(
    host: '192.168.1.10:5000',
    cgi: SynoEndpoints.entryCgi,
    https: false,
    query: <String, String?>{'_sid': 'abc-123', 'method': 'List'},
  );
  check(entryUrl.contains('_sid=abc-123'), 'SID 注入');
  check(!entryUrl.contains('5000:5000'), '端口不重复');

  print('── SynoResponse / 错误码 ──');
  final ok =
      SynoResponse.fromBody('{"success":true,"data":{"sid":"XYZ","did":"D1"}}');
  check(ok.success && ok.data!['sid'] == 'XYZ', '成功响应解析 SID');
  final fail = SynoResponse.fromBody('{"success":false,"error":{"code":400}}');
  check(!fail.success && fail.error!.code == 400, '失败响应解析错误码');
  check(SynoErrorCode.describe(106).contains('超时'), '错误码可读映射');
  var threw = false;
  try {
    fail.requireData();
  } on SynoException catch (e) {
    threw = e.code == 400;
  }
  check(threw, 'requireData 抛出携带错误码的 SynoException');
  check(SynoException.fromCode(107).needsReLogin, '会话失效标记需重登');

  print('── 两步验证（2FA）/ DSM Login Web API Guide ──');
  // 官方：403=需要验证码、404=验证码失败、406=强制2FA、400=账号或密码错误。
  check(SynoErrorCode.otpRequired == 403, '403 = 需要两步验证码');
  check(SynoErrorCode.otpInvalid == 404, '404 = 验证码认证失败');
  check(SynoErrorCode.otpEnforced == 406, '406 = 强制要求两步验证');
  check(SynoErrorCode.badCredentials == 400, '400 = 账号或密码错误');
  check(
      SynoErrorCode.describe(403).contains('两步验证') &&
          SynoErrorCode.describe(403).contains('验证码'),
      '403 文案引导输入验证码（不再误报密码错误）');
  check(SynoErrorCode.describe(404).contains('验证码错误'), '404 文案提示验证码错误');
  check(SynoException.fromCode(403).needsOtp, '403 → needsOtp');
  check(SynoException.fromCode(404).needsOtp, '404 → needsOtp');
  check(SynoException.fromCode(406).needsOtp, '406 → needsOtp');
  check(!SynoException.fromCode(400).needsOtp, '400 不触发 OTP（真·密码错误）');
  check(SynoException.fromCode(404).otpRejected, '404 → otpRejected');
  check(!SynoException.fromCode(403).otpRejected, '403 非 otpRejected');
  check(!SynoException.fromCode(403).needsReLogin, '403 不应误判为会话失效');

  // 带 otp_code + 设备令牌的登录 URL。
  final otpUrl = buildSynoUrl(
    host: '192.168.1.10',
    cgi: SynoEndpoints.authCgi,
    https: true,
    query: <String, String?>{
      'api': SynoApi.auth,
      'version': '6',
      'method': 'login',
      'account': 'admin',
      'passwd': 'pw',
      'otp_code': '123456',
      'enable_device_token': 'yes',
      'device_name': 'SynoCam iOS',
    },
  );
  check(otpUrl.contains('otp_code=123456'), 'otp_code 正确透传');
  check(otpUrl.contains('enable_device_token=yes'), '设备令牌开关透传');
  check(otpUrl.contains('device_name=SynoCam'), '设备名透传');

  // 免验证码登录：只带 device_id，不带 otp_code。
  final trustedUrl = buildSynoUrl(
    host: '192.168.1.10',
    cgi: SynoEndpoints.authCgi,
    https: true,
    query: <String, String?>{
      'api': SynoApi.auth,
      'version': '6',
      'method': 'login',
      'device_id': 'DID-XYZ',
      'device_name': 'SynoCam iOS',
    },
  );
  check(
      trustedUrl.contains('device_id=DID-XYZ') &&
          !trustedUrl.contains('otp_code'),
      '信任设备登录只带 device_id，不带 otp_code');

  print('── Camera 模型映射 ──');
  final cams = Camera.listFromData(<String, dynamic>{
    'cameras': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 1,
        'newName': '前门',
        'camModel': 'BC500',
        'ip': '192.168.1.101',
        'status': 1,
        'enabled': 1,
        'ptz': 1
      },
      <String, dynamic>{'cameraId': 2, 'name': '车库', 'enabled': 0, 'status': 0},
    ],
  });
  check(cams.length == 2, '列表解析 2 台');
  check(cams[0].name == '前门' && cams[0].ptzCapable, '字段别名 + PTZ 能力');
  check(cams[0].isOnline, '在线判定');
  check(!cams[1].isOnline, '停用判定');
  check(cams[0].copyWith(name: '大门').name == '大门', 'copyWith');

  print('── Session / SecureStore ──');
  const s = SynoSession(
      sid: 'S1', host: 'nas', account: 'admin', https: true, port: 5001);
  check(s.baseUrl == 'https://nas:5001', 'baseUrl 拼接');
  check(SynoSession.fromJson(s.toJson()).sid == 'S1', 'Session 序列化往返');
  final store = InMemorySecureStore();
  await store.saveSession(s);
  await store.saveCredentials('admin', 'secret');
  await store.saveDeviceId('nas.example.com', 'admin', 'DID-1');
  await store.saveDeviceId('nas.example.com', 'guest', 'DID-2');
  check((await store.readSession())!.sid == 'S1', '会话持久化');
  check((await store.readCredentials())!.password == 'secret', '凭据持久化');
  check(await store.readDeviceId('nas.example.com', 'admin') == 'DID-1',
      '设备令牌按 host|account 保存');
  check(await store.readDeviceId('nas.example.com', 'guest') == 'DID-2',
      '同 NAS 不同账号令牌互不串用');
  check(
      await store.readDeviceId('other.nas', 'admin') == null, '未信任的 host 无令牌');
  await store.clear();
  check(await store.readSession() == null, 'clear 清空');
  check(await store.readDeviceId('nas.example.com', 'admin') == null,
      'clear 同时清空设备令牌');

  print('── FeatureFlags ──');
  final flags = FeatureFlags();
  check(flags.isEnabled('live_h265_hardware_decode_enabled'), '默认值 true');
  check(!flags.isEnabled('notification_push_v2_enabled'), '默认值 false');
  check(!flags.isEnabled('unknown_key'), '未登记 key 安全默认 false');
  flags.attachRemote((k) => k == 'notification_push_v2_enabled' ? true : null);
  check(flags.isEnabled('notification_push_v2_enabled'), '远程覆盖生效');

  print('── AppConfig ──');
  check(AppConfig.gridLayouts.contains(9), '支持 3×3 布局');
  check(
      AppConfig.playbackSpeeds.first == 0.25 &&
          AppConfig.playbackSpeeds.last == 5.0,
      '回放倍速覆盖 0.25x–5x');

  print('── 真实 API 链路（清除演示数据后的能力）──');
  check(
      SynoMethod.queryEvents == 'Query', 'SS 录像事件用 Query（非 List，method 首字母大写）');
  check(SynoMethod.queryApiInfo == 'query', 'API Info 用小写 query');
  check(SynoApi.videoStream == 'SYNO.SurveillanceStation.Stream.VideoStreaming',
      'MJPEG 直播流 API 名');
  check(SynoEndpoints.cgiFromPath('entry.cgi') == '/webapi/entry.cgi',
      'API Info path 拼接为完整 CGI');
  check(SynoEndpoints.cgiFromPath(null) == SynoEndpoints.entryCgi,
      'path 缺失时回退 entry.cgi');
  final info = parseApiInfo(<String, dynamic>{
    'SYNO.SurveillanceStation.Camera': <String, dynamic>{
      'maxVersion': 9,
      'minVersion': 1,
      'path': 'entry.cgi',
    },
    'SYNO.SurveillanceStation.Event': <String, dynamic>{
      'maxVersion': 2,
      'minVersion': 1,
      'path': 'entry.cgi',
    },
  });
  check(info['SYNO.SurveillanceStation.Camera']!.effectiveVersion() == 9,
      'Camera 使用 NAS maxVersion 与实现依据上限的较小值');
  check(info['SYNO.SurveillanceStation.Event']!.effectiveVersion() == 1,
      'Event 不被 NAS 的更高 maxVersion 带偏（按实现依据取 1）');
  check(SynoErrorCode.isUnsupported(102) && SynoErrorCode.isUnsupported(103),
      'API/方法不存在用于真实接口回退判定');
  check(SynoException.fromCode(102).diagnostic.contains('错误码 102'),
      '异常携带可定位的 DSM 错误码');

  final camWithKey = Camera.fromSynoJson(<String, dynamic>{
    'id': 7,
    'name': '前门',
    'streamInfo': <String, dynamic>{'stmKey': 'ABC123456789'},
  });
  check(camWithKey.stmKey == 'ABC123456789' && camWithKey.canStream,
      '嵌套 streamInfo 中解析出真实 StmKey');
  final camWithPath = Camera.fromSynoJson(<String, dynamic>{
    'id': 8,
    'name': '车库',
    'mjpegHttpPath':
        'http://nas:5000/webapi/entry.cgi?api=SYNO.SurveillanceStation.Stream.VideoStreaming&method=Stream&StmKey="XYZ987654321"',
  });
  check(camWithPath.canStream, '从 GetLiveViewPath 完整 URL 提取 StmKey');
  check(!const Camera(id: 9, name: '无流凭证').canStream, '无凭证时 UI 明确提示而非伪造画面');

  final rec = Recording.fromEventJson(<String, dynamic>{
    'id': 500,
    'cameraId': 1,
    'startTime': 1330640410,
    'stopTime': 1330640470,
    'status': 2,
    'mode': 1,
    'videoCodec': 'H264',
  }, <int, String>{
    1: '前门'
  });
  check(rec.durationSeconds == 60 && rec.locked, '真实事件解析时长与锁定状态');
  check(
      rec.eventType == '移动侦测' && rec.cameraName == '前门', '录制模式映射为可读类型 + 摄像机名');
  check(rec.dateLabel.startsWith('2012'), '录像分组日期来自真实时间戳');
  check(SurveillanceEvent.fromRecording(rec).type == 'motion', '通知事件由真实录像派生');

  final noStop = Recording.fromEventJson(<String, dynamic>{
    'id': 501,
    'cameraId': 1,
    'startTime': 1330640410,
    'duration': 45,
    'status': 2,
  }, const <int, String>{});
  check(noStop.durationSeconds == 45,
      '缺 stopTime 时从显式 duration 字段取真实时长（不再退化为 0）');
  final recordingNow = Recording.fromEventJson(<String, dynamic>{
    'id': 502,
    'cameraId': 1,
    'startTime': DateTime.now()
            .subtract(const Duration(seconds: 30))
            .millisecondsSinceEpoch ~/
        1000,
    'status': 1,
  }, const <int, String>{});
  check(recordingNow.durationSeconds >= 29, '仍在录制且无结束时间时用「此刻 - 开始」得到真实已录时长');
  check(
      noStop.playbackDurationSeconds == 45 &&
          noStop.playbackEndTime.difference(noStop.startTime).inSeconds == 45,
      '回放跨度与结束时刻由真实时长推导，下载与回放流一致');
  final unknown = Recording(
      id: 'x',
      cameraId: 1,
      cameraName: 'c',
      startTime: DateTime(2024, 5, 1, 9, 0),
      durationSeconds: 0);
  check(
      unknown.playbackDurationSeconds == 60 &&
          unknown.playbackEndTime.hour == 9 &&
          unknown.playbackEndTime.minute == 1,
      '时长完全未知时回放统一取 60 秒，不再只请求 1 秒画面');
  check(
      TimelineMath.dateTimeLabel(DateTime(2024, 5, 1, 9, 5, 3)) ==
          '2024-05-01 09:05:03',
      '完整日期时间标签避免跨天/时区混淆');

  print('── 流端点会话 Cookie（HTTP 465「画面加载失败」根因）──');
  const ss = SynoSession(
      sid: 'SID-9',
      host: 'nas',
      account: 'admin',
      https: true,
      port: 5001,
      did: 'DID-7');
  check(ss.cookieHeader == 'id=SID-9; did=DID-7',
      'Cookie 同时带 id=<sid> 与 did=<设备令牌>');
  check(
      const SynoSession(
                  sid: 'S', host: 'nas', account: 'a', https: false, port: 5000)
              .cookieHeader ==
          'id=S',
      '无设备令牌时 Cookie 仅带 id');
  check(SynoSession.fromJson(ss.toJson()).cookieHeader == 'id=SID-9; did=DID-7',
      '会话序列化往返后 Cookie 仍可重建');

  print('── 媒体字节识别（区分真画面与 DSM 错误 JSON）──');
  check(
      MediaBytes.isImage(<int>[0xFF, 0xD8, 0xFF, 0xE0, 0x00]), 'JPEG 头识别为真图片');
  check(MediaBytes.isImage(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D]), 'PNG 头识别为真图片');
  check(!MediaBytes.isImage(<int>[0x7B, 0x22, 0x65, 0x72]), 'JSON 开头不会误判为图片');
  check(!MediaBytes.isImage(<int>[0xFF, 0xD8]), '过短字节不是图片');
  check(MediaBytes.looksLikeJsonError('{"error":{"code":400}}'.codeUnits),
      'DSM 错误 JSON（HTTP 200）被识别为失败响应');
  check(MediaBytes.looksLikeJsonError(<int>[]), '空响应视为失败');
  check(
      !MediaBytes.looksLikeJsonError(
          <int>[0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]),
      'MP4 二进制不被误判为 JSON 错误');
  check(
      MediaBytes.extensionFor(<int>[
            0,
            0,
            0,
            24,
            0x66,
            0x74,
            0x79,
            0x70,
            0x69,
            0x73,
            0x6F,
            0x6D
          ]) ==
          '.mp4',
      'MP4 ftyp 文件头推断 .mp4');
  check(MediaBytes.extensionFor(<int>[0x1A, 0x45, 0xDF, 0xA3]) == '.mkv',
      'Matroska 文件头推断 .mkv');
  check(MediaBytes.extensionFor(<int>[0x52, 0x49, 0x46, 0x46]) == '.avi',
      'RIFF 文件头推断 .avi');
  check(
      MediaBytes.extensionFor(<int>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) ==
          '.mp4',
      '未知格式安全回退 .mp4（video_player 可尝试打开）');
  const rf = RecordingFile(
      bytes: <int>[1, 2, 3],
      extension: '.mp4',
      source: 'id,cameraId',
      contentType: 'video/mp4');
  check(
      rf.bytes.length == 3 &&
          rf.extension == '.mp4' &&
          rf.source.isNotEmpty &&
          rf.contentType == 'video/mp4',
      '真实录像文件模型携带来源与格式');
  check(rf.startsAt == null, '未标注起点时录像文件起点为空（回放页按片段 seek）');

  print('── 按选中时刻回放窗口（修复「回放播放实时画面 / 不是选中时刻」）──');
  final winClip = Recording(
      id: 'e1',
      cameraId: 2,
      cameraName: 'c2',
      startTime: DateTime(2026, 11, 10, 10, 0),
      durationSeconds: 600);
  final atIn = DateTime(2026, 11, 10, 10, 3, 20);
  final wIn = recordingWindowFor(winClip, atIn);
  check(wIn.startsAtTarget, '选中时刻落在片段内时按该时刻请求');
  check(
      wIn.from == atIn.millisecondsSinceEpoch ~/ 1000 &&
          wIn.to == winClip.playbackEndTime.millisecondsSinceEpoch ~/ 1000,
      '请求窗口起点=选中时刻、终点=片段回放终点');
  check(wIn.seekSeconds == 200, '按 id 下载整段时的偏移=选中时刻-片段起点');
  final atOut = DateTime(2026, 11, 10, 12, 0);
  final wOut = recordingWindowFor(winClip, atOut);
  check(!wOut.startsAtTarget && wOut.seekSeconds == 0, '选中时刻在片段外时回退到片段起点、不做偏移');
  check(wOut.to > wOut.from, '请求窗口至少有正跨度，不出现 1 秒空窗');
  final winNoStop = Recording(
      id: 'e2',
      cameraId: 2,
      cameraName: 'c2',
      startTime: DateTime(2026, 11, 10, 10, 0),
      durationSeconds: 0);
  final wNoStop =
      recordingWindowFor(winNoStop, DateTime(2026, 11, 10, 10, 0, 30));
  check(wNoStop.to - wNoStop.from >= 60, '缺 stopTime 的片段窗口至少 60 秒（不会只请求 1 秒）');
  final rfAt = RecordingFile(
      bytes: <int>[1],
      extension: '.mp4',
      source: 'cameraId,startTime,stopTime',
      startsAt: DateTime(2026, 11, 10, 10, 3, 20));
  check(rfAt.startsAt != null, '按时间段下载成功时录像文件标注真实起点=选中时刻');

  print('── MJPEG 流解析（App 内连续画面 / 回放画面）──');
  check(indexOfBytes(<int>[1, 2, 3, 4, 5], <int>[3, 4]) == 2, '字节子序列定位');
  check(indexOfBytes(<int>[1, 2, 3], <int>[9]) == -1, '未找到返回 -1');
  check(indexOfBytes(<int>[1, 2, 1, 2], <int>[1, 2], 1) == 2, '指定起点后继续查找');
  check(
      boundaryFrom('multipart/x-mixed-replace; boundary=myBoundary') ==
          'myBoundary',
      '提取无引号 boundary');
  check(
      boundaryFrom('multipart/x-mixed-replace; boundary="quoted-b"') ==
          'quoted-b',
      '提取带引号 boundary');
  check(boundaryFrom('image/jpeg') == '', '无 boundary 返回空串');

  final jpeg = <int>[0xFF, 0xD8, 0xFF, 0x01, 0x02];
  final part = <int>[
    ...'--B\r\nContent-Type: image/jpeg\r\nContent-Length: 5\r\n\r\n'.codeUnits,
    ...jpeg,
    ...'\r\n--B\r\nContent-Type: image/jpeg\r\nContent-Length: 5\r\n\r\n'
        .codeUnits,
    ...jpeg,
    ...'\r\n--B--\r\n'.codeUnits,
  ];
  final frames = await parseMjpegFrames(
          Stream<List<int>>.fromIterable(<List<int>>[part]), 'B')
      .toList();
  check(frames.length == 2, 'multipart 流按 Content-Length 精确切出 2 帧');
  check(
      frames.first.length == 5 && frames.first[0] == 0xFF, '切出的首帧是完整 JPEG 字节');
  check(frames.last[4] == 0x02, '第二帧字节完整');

  final raw = <int>[
    0xFF, 0xD8, 0xFF, 0xAA, 0xFF, 0xD9, // 帧 1
    0xFF, 0xD8, 0xFF, 0xBB, 0xFF, 0xD9, // 帧 2
  ];
  final rawFrames =
      await parseRawJpegFrames(Stream<List<int>>.fromIterable(<List<int>>[raw]))
          .toList();
  check(rawFrames.length == 2, '无 multipart 封装时按 SOI/EOI 切出 2 帧');
  check(rawFrames[0][3] == 0xAA && rawFrames[1][3] == 0xBB, '裸流两帧内容各自独立');

  List<List<int>> splitInto(List<int> src, int size) {
    final out = <List<int>>[];
    for (var i = 0; i < src.length; i += size) {
      final end = i + size > src.length ? src.length : i + size;
      out.add(src.sublist(i, end));
    }
    return out;
  }

  // 增量解析器的核心回归：boundary / 头 / 帧数据被网络拆到任意块边界，
  // 仍必须切出完整帧（旧实现在此场景会重复扫描甚至丢帧）。
  for (final size in <int>[1, 7, 13]) {
    final f = await parseMjpegFrames(
            Stream<List<int>>.fromIterable(splitInto(part, size)), 'B')
        .toList();
    check(f.length == 2 && f.first.length == 5 && f.last[4] == 0x02,
        'MJPEG 跨 $size 字节网络块边界仍切出 2 帧完整 JPEG');
    final r = await parseRawJpegFrames(
            Stream<List<int>>.fromIterable(splitInto(raw, size)))
        .toList();
    check(r.length == 2 && r[0][3] == 0xAA && r[1][3] == 0xBB,
        '裸 JPEG 流跨 $size 字节块边界仍切出 2 帧');
  }
  final noLen = <int>[
    ...'--B\r\nContent-Type: image/jpeg\r\n\r\n'.codeUnits,
    ...jpeg,
    ...'\r\n--B\r\nContent-Type: image/jpeg\r\n\r\n'.codeUnits,
    ...jpeg,
    ...'\r\n--B--\r\n'.codeUnits,
  ];
  final noLenFrames = await parseMjpegFrames(
          Stream<List<int>>.fromIterable(splitInto(noLen, 5)), 'B')
      .toList();
  check(noLenFrames.length == 2, '无 Content-Length 时按 boundary 跨块切帧');
  final bigFrame = <int>[
    0xFF,
    0xD8,
    0xFF,
    ...List<int>.filled(70000, 0x37),
    0xFF,
    0xD9
  ];
  final bigPart = <int>[
    ...'--B\r\nContent-Length: ${bigFrame.length}\r\n\r\n'.codeUnits,
    ...bigFrame,
    ...'\r\n--B--\r\n'.codeUnits,
  ];
  final bigFrames = await parseMjpegFrames(
          Stream<List<int>>.fromIterable(splitInto(bigPart, 4096)), 'B')
      .toList();
  check(bigFrames.length == 1 && bigFrames.first.length == bigFrame.length,
      '大帧跨块 + 缓冲区紧凑化后字节完整（不再 O(n²) 搬移）');
  check(MjpegStreamClient(url: 'http://nas/x', maxFps: 15).maxFps == 15,
      '流客户端可配置上限帧率，网络快于解码时丢过期帧');

  print('── 时间轴拖动 / App 内片段回放 ──');
  final day = DateTime(2024, 5, 1);
  check(TimelineMath.secondsPerDay == 86400, '一天 86400 秒');
  check(
      (TimelineMath.fractionOf(day.add(const Duration(hours: 6)), day) - 0.25)
              .abs() <
          1e-9,
      '06:00 映射到 0.25');
  check(TimelineMath.timeAt(0.5, day).hour == 12, '0.5 还原为 12:00');
  check(TimelineMath.timeLabel(DateTime(2024, 5, 1, 9, 5, 3)) == '09:05:03',
      '时间标签补零');
  check(TimelineMath.fractionOf(day.add(const Duration(days: 2)), day) == 1.0,
      '越界上钳到 1');
  check(
      TimelineMath.fractionOf(day.subtract(const Duration(hours: 5)), day) ==
          0.0,
      '越界下钳到 0');
  final clip = Recording(
    id: 'c1',
    cameraId: 1,
    cameraName: '前门',
    startTime: day.add(const Duration(hours: 10)),
    durationSeconds: 600,
  );
  check(clip.endTime == day.add(const Duration(hours: 10, minutes: 10)),
      'endTime = startTime + duration');
  check(
      Recording(
                  id: 'c2',
                  cameraId: 1,
                  cameraName: '录制中',
                  startTime: DateTime(2024),
                  durationSeconds: 0,
                  recording: true)
              .durationLabel ==
          '录制中',
      '录制中的片段不给虚假时长');
  check(
      TimelineMath.clipAt(<Recording>[clip],
              day.add(const Duration(hours: 10, minutes: 5))) ==
          clip,
      '拖动命中片段');
  check(
      TimelineMath.clipAt(
              <Recording>[clip], day.add(const Duration(hours: 11))) ==
          null,
      '拖动到空白处不命中');
  check(
      TimelineMath.nearestClip(
              <Recording>[clip], day.add(const Duration(hours: 23))) ==
          clip,
      '拖动到空白时取最近的真实片段');
  check(TimelineMath.nearestClip(<Recording>[], day) == null,
      '无片段时返回 null（UI 显示真实空态）');

  // 修复「回放的是临近时间，不是选中时刻」：缺 stopTime 的片段 endTime 只有
  // +1 秒，旧 clipAt 几乎永不命中，只能回退到「最近片段」。现在按回放跨度判定。
  final noStopClip = Recording(
      id: 'c3',
      cameraId: 1,
      cameraName: '缺结束时间',
      startTime: day.add(const Duration(hours: 12)),
      durationSeconds: 0);
  check(
      TimelineMath.clipAt(<Recording>[noStopClip],
              day.add(const Duration(hours: 12, seconds: 30))) ==
          noStopClip,
      '缺 stopTime 的片段按 replay 跨度命中（不再只回退最近片段）');
  check(
      TimelineMath.clipAt(<Recording>[noStopClip],
              day.add(const Duration(hours: 12, minutes: 2))) ==
          null,
      '超出回放跨度仍不命中');
  check(
      TimelineMath.seekSecondsInClip(
              clip, day.add(const Duration(hours: 10, minutes: 3))) ==
          180,
      '选中时刻换算为片段内偏移秒数（回放从该秒起播）');
  check(
      TimelineMath.seekSecondsInClip(clip, day.add(const Duration(hours: 9))) ==
          0,
      '选中时刻早于片段起点时偏移夹到 0');
  check(
      TimelineMath.seekSecondsInClip(
              clip, day.add(const Duration(hours: 11))) ==
          600,
      '选中时刻晚于片段末尾时偏移夹到片段时长');

  print('── 会话失效闭环（HTTP 465 / 登录页 HTML）──');
  check(SynoErrorCode.portalAuthRequired == 465, 'DSM 门户拦截码 465');
  check(SynoErrorCode.ipMismatch == 150, '登录来源 IP 变化码 150');
  check(SynoException.fromCode(465).needsReLogin, '465 触发重新登录');
  check(SynoException.fromCode(150).needsReLogin, '150 触发重新登录');
  check(SynoErrorCode.describe(465).contains('重新登录'), '465 文案引导重新登录');
  check(!SynoErrorCode.describe(465).contains('地址/端口'), '465 文案不再误导为地址/端口配置错误');
  check(SynoErrorCode.describe(150).contains('重新登录'), '150 文案引导重新登录');
  final loginHtml = '<!DOCTYPE html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width"></head>'
      '<body>Synology DSM login</body></html>';
  final portal465 = classifyHttpResponse(465, loginHtml);
  check(
      portal465.code == SynoErrorCode.portalAuthRequired &&
          portal465.needsReLogin,
      'HTTP 465 + 登录页 HTML → 会话失效（不再降级错误码 100）');
  check(classifyHttpResponse(200, loginHtml).needsReLogin,
      'HTTP 200 + 登录页 HTML（门户重定向）→ 会话失效');
  final json465 =
      classifyHttpResponse(465, '{"success":false,"error":{"code":400}}');
  check(!json465.needsReLogin && json465.code == 400,
      '465 + JSON 业务错误 → 流端点问题，不误判会话失效（修复登录后被踢出）');
  final notFound = classifyHttpResponse(
      404, '<html><body><h1>404 Not Found</h1></body></html>');
  check(!notFound.needsReLogin, '404 普通网页不误判为会话失效');
  check(notFound.message.contains('地址/端口/HTTPS'), '404 保留地址/端口/HTTPS 类建议');
  check(!classifyHttpResponse(500, 'upstream error').needsReLogin,
      '非 HTML 非 JSON 错误不误判为会话失效');
  check(!classifyHttpResponse(200, '{"success":true,"data":{}}').needsReLogin,
      '正常 JSON 响应不受影响');

  print('── 防止把普通网页误判为会话过期（本轮登录被踢出的根因）──');
  final ssWebUi = '<!DOCTYPE html><html><head><meta name="viewport" '
      'content="width=device-width"></head><body>'
      '<div id="surveillance-station">Loading...</div></body></html>';
  check(!classifyHttpResponse(200, ssWebUi).needsReLogin,
      '200 + 普通 HTML（含 viewport / width=device-width）不误判会话失效');
  check(classifyHttpResponse(200, ssWebUi).message.contains('地址/端口/HTTPS'),
      '普通 HTML 保留地址/端口/HTTPS 类建议');
  check(classifyHttpResponse(465, '').needsReLogin, '465 + 空 body（门户拦截）判会话失效');
  check(!classifyHttpResponse(465, '\xff\xd8\xff\xe0binary').needsReLogin,
      '465 + 二进制乱码不误判会话失效');
  check(!classifyFailure('NAS 返回业务错误码 400（HTTP 465）').needsReLogin,
      '465 文本但属业务错误时不误判会话失效');

  print('── 登录保护窗口（刚登录不被辅助端点踢回登录页）──');
  final guard = SessionExpiryGuard();
  check(guard.shouldExpire(detected: true, hasSession: true), '默认允许真实会话失效触发重登');
  guard.suppress();
  check(guard.suppressed, 'suppress() 生效');
  check(!guard.shouldExpire(detected: true, hasSession: true),
      '登录后首次刷新保护窗口内不踢出（核心修复）');
  check(
      !guard.shouldExpire(
          detected: true, hasSession: true, authenticating: true),
      '登录请求期间不踢出');
  guard.release();
  check(
      !guard.suppressed && guard.shouldExpire(detected: true, hasSession: true),
      'release() 后恢复正常判定');
  check(!guard.shouldExpire(detected: true, hasSession: false), '无会话时不触发重登');
  check(
      !guard.shouldExpire(detected: false, hasSession: true), '未检测到失效信号时不触发重登');

  print('── 本轮修复：端口错配 / 402 权限 / 登录宽限期 / 诊断脱敏 ──');
  final mixed = buildSynoUrl(
    host: '192.168.1.10:5000',
    cgi: SynoEndpoints.authCgi,
    https: true,
    port: 5000,
    query: <String, String?>{'api': SynoApi.auth},
  );
  check(mixed.startsWith('https://192.168.1.10:5000/'), '地址带端口 + 显式端口时只拼一个端口');
  check(!mixed.contains('5000:5000'), 'host 内嵌端口被剥离，不再出现重复端口');
  check(!SynoException.fromCode(402).needsReLogin,
      '402 权限不足不再误判为会话失效（核心：不再踢回登录页）');
  check(!SynoException.fromCode(105).needsReLogin, '105 无权限不触发重登');
  final g2 = SessionExpiryGuard();
  g2.grantGrace(const Duration(minutes: 1));
  check(g2.suppressed, '登录后宽限期内抑制自动踢出');
  check(!g2.shouldExpire(detected: true, hasSession: true),
      '宽限期内首屏请求偶发 465 不踢回登录页');
  g2.clearGrace();
  check(!g2.suppressed && g2.shouldExpire(detected: true, hasSession: true),
      'clearGrace 后恢复正常判定');
  final safe = sanitizeApiUrl(
      'http://192.168.1.10:5000/webapi/auth.cgi?api=SYNO.API.Auth'
      '&method=login&account=admin&passwd=p%40ss&otp_code=123456&_sid=ABC');
  check(
      safe.contains('passwd=') && !safe.contains('p%40ss'), '登录诊断保留参数名但不回显密码');
  check(!safe.contains('123456') && !safe.contains('ABC'), '登录诊断不回显验证码与 SID');
  check(safe.contains('account=admin'), '登录诊断保留可定位的账号与地址');

  print('── 两步验证输入（会话过期预填 2FA 不阻塞登录）──');
  check(normalizeOtp(null) == null, 'null 视为未提供验证码');
  check(normalizeOtp('') == null, '空串视为未提供验证码');
  check(normalizeOtp('   ') == null, '纯空格视为未提供验证码');
  check(normalizeOtp(' 123456 ') == '123456', '有效验证码去首尾空格');
  check(normalizeOtp('123') == '123', '短验证码透传给表单校验提示');

  print('── UI 错误分类（不再一律误报地址/权限问题）──');
  check(classifyFailure(SynoException.fromCode(465)).needsReLogin,
      '465 异常 → 会话失效视图');
  check(classifyFailure(SynoException.fromCode(106)).needsReLogin,
      '106 异常 → 会话失效视图');
  check(classifyFailure('SynoException(465): 登录会话已过期，请重新登录').needsReLogin,
      '诊断文本 → 会话失效视图');
  check(
      classifyFailure('MjpegException: 登录会话已过期或被 NAS 登出，请重新登录（HTTP 465）')
          .needsReLogin,
      'MJPEG 465 文本 → 会话失效视图');
  check(
      classifyFailure('HTTPS 证书不受信任，若 NAS 使用自签证书').kind ==
          FailureKind.certificate,
      '证书错误独立分类');
  check(
      classifyFailure('连接超时，请检查地址与网络').kind == FailureKind.network, '网络超时独立分类');
  check(!classifyFailure('权限不足，请确认账号具备访问权限').needsReLogin, '权限错误不误判为会话失效');
  check(!classifyFailure(null).needsReLogin, '空错误不误判');
  check(needsReLoginError(SynoException.fromCode(465)),
      'needsReLoginError 覆盖异常对象');
  check(needsReLoginError('登录会话已过期，请重新登录'), 'needsReLoginError 覆盖纯文本');
  check(!needsReLoginError('错误码 102'), 'needsReLoginError 不误判普通错误');

  print('── 上次连接信息（会话失效后登录页预填，不含密码）──');
  const lc = LastConnection(
      host: 'nas.naeeeo.com',
      account: 'naeeo',
      https: true,
      port: 5001,
      twoFactor: true,
      trustDevice: true);
  final lc2 = LastConnection.fromJson(lc.toJson());
  check(lc2.host == 'nas.naeeeo.com' && lc2.account == 'naeeo',
      '连接信息序列化往返保留地址与账号');
  check(lc2.port == 5001 && lc2.https && lc2.twoFactor && lc2.trustDevice,
      '端口 / HTTPS / 2FA / 信任设备往返');
  check(
      !lc.toJson().containsKey('password') &&
          !lc.toJson().containsKey('passwd'),
      '连接信息绝不包含密码字段');
  check(
      !const LastConnection(host: '', account: 'a', https: true, port: 5001)
          .isValid,
      '空地址视为无效，不预填');
  check(LastConnection.fromJson(<String, dynamic>{}).https, '缺失字段安全默认 HTTPS');

  print('── NAS 时间展示校准（修复录像画面时间不对）──');
  final t0 = DateTime(2026, 11, 10, 14, 30, 5);
  check(const TimeSync().clock(t0) == '14:30:05', '零偏移时显示 NAS 原始解析时刻');
  check(const TimeSync(-480).clock(t0) == '06:30:05', '-8 小时校准把显示时刻对齐摄像机 OSD');
  check(const TimeSync(480).clock(t0) == '22:30:05', '+8 小时校准方向正确');
  check(const TimeSync(-480).full(t0) == '2026-11-10 06:30:05', '完整日期时间标签应用校准');
  check(const TimeSync(-480).short(t0) == '11-10 06:30:05', '短标签应用校准');
  check(const TimeSync(0).offsetLabel.contains('未校准'), '零偏移提示未校准');
  check(const TimeSync(-480).offsetLabel == '-8 小时', '偏移文案可读');
  check(const TimeSync(90).offsetLabel == '+1 小时 30 分钟', '非整点偏移文案可读');
  check(const TimeSync(-480).compare(t0).contains('本机 14:30:05 · NAS 06:30:05'),
      '设置页对照同时给出本机与换算后 NAS 时刻');
  check(
      TimeSync.formatClock(t0) == '14:30:05' &&
          TimeSync.formatFull(t0) == '2026-11-10 14:30:05',
      '静态格式化方法可直接复用');

  print('\n✅ 全部 $_checks 项断言通过');
}
