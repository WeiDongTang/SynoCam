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
import '../lib/core/network/syno_api.dart';
import '../lib/core/storage/secure_store.dart';
import '../lib/data/models/camera.dart';
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

  print('\n✅ 全部 $_checks 项断言通过');
}
