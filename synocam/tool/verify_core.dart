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
  check(SynoMethod.queryEvents == 'Query',
      'SS 录像事件用 Query（非 List，method 首字母大写）');
  check(SynoMethod.queryApiInfo == 'query', 'API Info 用小写 query');
  check(SynoApi.videoStream ==
      'SYNO.SurveillanceStation.Stream.VideoStreaming', 'MJPEG 直播流 API 名');
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
  check(!const Camera(id: 9, name: '无流凭证').canStream,
      '无凭证时 UI 明确提示而非伪造画面');

  final rec = Recording.fromEventJson(<String, dynamic>{
    'id': 500,
    'cameraId': 1,
    'startTime': 1330640410,
    'stopTime': 1330640470,
    'status': 2,
    'mode': 1,
    'videoCodec': 'H264',
  }, <int, String>{1: '前门'});
  check(rec.durationSeconds == 60 && rec.locked, '真实事件解析时长与锁定状态');
  check(rec.eventType == '移动侦测' && rec.cameraName == '前门',
      '录制模式映射为可读类型 + 摄像机名');
  check(rec.dateLabel.startsWith('2012'), '录像分组日期来自真实时间戳');
  check(SurveillanceEvent.fromRecording(rec).type == 'motion',
      '通知事件由真实录像派生');

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
              sid: 'S',
              host: 'nas',
              account: 'a',
              https: false,
              port: 5000)
          .cookieHeader ==
          'id=S',
      '无设备令牌时 Cookie 仅带 id');
  check(
      SynoSession.fromJson(ss.toJson()).cookieHeader == 'id=SID-9; did=DID-7',
      '会话序列化往返后 Cookie 仍可重建');

  print('── 媒体字节识别（区分真画面与 DSM 错误 JSON）──');
  check(MediaBytes.isImage(<int>[0xFF, 0xD8, 0xFF, 0xE0, 0x00]),
      'JPEG 头识别为真图片');
  check(MediaBytes.isImage(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D]),
      'PNG 头识别为真图片');
  check(!MediaBytes.isImage(<int>[0x7B, 0x22, 0x65, 0x72]),
      'JSON 开头不会误判为图片');
  check(!MediaBytes.isImage(<int>[0xFF, 0xD8]), '过短字节不是图片');
  check(
      MediaBytes.looksLikeJsonError('{"error":{"code":400}}'.codeUnits),
      'DSM 错误 JSON（HTTP 200）被识别为失败响应');
  check(MediaBytes.looksLikeJsonError(<int>[]), '空响应视为失败');
  check(
      !MediaBytes.looksLikeJsonError(
          <int>[0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]),
      'MP4 二进制不被误判为 JSON 错误');
  check(
      MediaBytes.extensionFor(<int>[
        0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D
      ]) ==
          '.mp4',
      'MP4 ftyp 文件头推断 .mp4');
  check(MediaBytes.extensionFor(<int>[0x1A, 0x45, 0xDF, 0xA3]) == '.mkv',
      'Matroska 文件头推断 .mkv');
  check(MediaBytes.extensionFor(<int>[0x52, 0x49, 0x46, 0x46]) == '.avi',
      'RIFF 文件头推断 .avi');
  check(
      MediaBytes.extensionFor(
              <int>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) ==
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

  print('── MJPEG 流解析（App 内连续画面 / 回放画面）──');
  check(indexOfBytes(<int>[1, 2, 3, 4, 5], <int>[3, 4]) == 2,
      '字节子序列定位');
  check(indexOfBytes(<int>[1, 2, 3], <int>[9]) == -1, '未找到返回 -1');
  check(indexOfBytes(<int>[1, 2, 1, 2], <int>[1, 2], 1) == 2,
      '指定起点后继续查找');
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
    ...'--B\r\nContent-Type: image/jpeg\r\nContent-Length: 5\r\n\r\n'
        .codeUnits,
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
  check(frames.first.length == 5 && frames.first[0] == 0xFF,
      '切出的首帧是完整 JPEG 字节');
  check(frames.last[4] == 0x02, '第二帧字节完整');

  final raw = <int>[
    0xFF, 0xD8, 0xFF, 0xAA, 0xFF, 0xD9, // 帧 1
    0xFF, 0xD8, 0xFF, 0xBB, 0xFF, 0xD9, // 帧 2
  ];
  final rawFrames = await parseRawJpegFrames(
          Stream<List<int>>.fromIterable(<List<int>>[raw]))
      .toList();
  check(rawFrames.length == 2, '无 multipart 封装时按 SOI/EOI 切出 2 帧');
  check(rawFrames[0][3] == 0xAA && rawFrames[1][3] == 0xBB,
      '裸流两帧内容各自独立');

  print('── 时间轴拖动 / App 内片段回放 ──');
  final day = DateTime(2024, 5, 1);
  check(TimelineMath.secondsPerDay == 86400, '一天 86400 秒');
  check(
      (TimelineMath.fractionOf(
                  day.add(const Duration(hours: 6)), day) -
              0.25)
          .abs() <
          1e-9,
      '06:00 映射到 0.25');
  check(TimelineMath.timeAt(0.5, day).hour == 12, '0.5 还原为 12:00');
  check(
      TimelineMath.timeLabel(DateTime(2024, 5, 1, 9, 5, 3)) == '09:05:03',
      '时间标签补零');
  check(TimelineMath.fractionOf(day.add(const Duration(days: 2)), day) == 1.0,
      '越界上钳到 1');
  check(
      TimelineMath.fractionOf(
              day.subtract(const Duration(hours: 5)), day) ==
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

  print('\n✅ 全部 $_checks 项断言通过');
}
