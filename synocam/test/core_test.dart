// 核心协议层单元测试（CI: flutter test）。
// 覆盖：URL 构造、响应/错误码解析、Camera 字段别名映射、功能开关默认与覆盖。
import 'package:flutter_test/flutter_test.dart';

import 'package:synocam/core/config/feature_flags.dart';
import 'package:synocam/core/network/syno_api.dart';
import 'package:synocam/data/models/camera.dart';

void main() {
  group('buildSynoUrl', () {
    test('HTTP 默认端口 5000 + 参数编码', () {
      final url = buildSynoUrl(
        host: '192.168.1.10',
        cgi: SynoEndpoints.authCgi,
        https: false,
        query: <String, String?>{
          'api': SynoApi.auth,
          'version': '6',
          'method': 'login',
          'passwd': 'p@ss',
          'otp_code': null,
        },
      );
      expect(
          url.startsWith('http://192.168.1.10:5000/webapi/auth.cgi'), isTrue);
      expect(url.contains('api=SYNO.API.Auth'), isTrue);
      expect(url.contains('passwd=p%40ss'), isTrue);
      expect(url.contains('otp_code'), isFalse); // null 被剔除
    });

    test('host 自带 https 时自动切 5001', () {
      final url = buildSynoUrl(
        host: 'https://nas.example.com',
        cgi: SynoEndpoints.entryCgi,
        https: false,
        query: <String, String?>{'api': SynoApi.camera},
      );
      expect(url.startsWith('https://nas.example.com:5001/'), isTrue);
    });

    test('显式端口不重复', () {
      final url = buildSynoUrl(
        host: '192.168.1.10:5000',
        cgi: SynoEndpoints.entryCgi,
        https: false,
        query: <String, String?>{'_sid': 'abc'},
      );
      expect(url.contains('5000:5000'), isFalse);
      expect(url.contains('_sid=abc'), isTrue);
    });
  });

  group('SynoResponse / 错误码', () {
    test('成功响应解析 SID', () {
      final r = SynoResponse.fromBody('{"success":true,"data":{"sid":"XYZ"}}');
      expect(r.success, isTrue);
      expect(r.requireData()['sid'], 'XYZ');
    });

    test('失败响应抛出携带错误码的异常', () {
      final r = SynoResponse.fromBody('{"success":false,"error":{"code":400}}');
      expect(r.error!.code, 400);
      expect(
        () => r.requireData(),
        throwsA(isA<SynoException>().having((e) => e.code, 'code', 400)),
      );
    });

    test('会话失效错误标记需重登', () {
      expect(SynoException.fromCode(106).needsReLogin, isTrue);
      expect(SynoException.fromCode(107).needsReLogin, isTrue);
      expect(SynoException.fromCode(400).needsReLogin, isFalse);
    });
  });

  group('两步验证 2FA（DSM Login Web API Guide）', () {
    test('官方错误码定义', () {
      expect(SynoErrorCode.badCredentials, 400); // 账号或密码错误
      expect(SynoErrorCode.otpRequired, 403); // 需要两步验证码
      expect(SynoErrorCode.otpInvalid, 404); // 验证码认证失败
      expect(SynoErrorCode.otpEnforced, 406); // 强制要求 2FA
    });

    test('403 文案引导输入验证码，而非误报密码错误', () {
      final msg = SynoErrorCode.describe(403);
      expect(msg.contains('两步验证'), isTrue);
      expect(msg.contains('验证码'), isTrue);
      expect(msg.contains('密码错误'), isFalse);
      expect(SynoErrorCode.describe(404).contains('验证码错误'), isTrue);
    });

    test('needsOtp / otpRejected 判定', () {
      for (final code in <int>[403, 404, 406]) {
        expect(SynoException.fromCode(code).needsOtp, isTrue,
            reason: '$code 应触发 OTP 输入框');
      }
      expect(SynoException.fromCode(400).needsOtp, isFalse);
      expect(SynoException.fromCode(403).needsReLogin, isFalse);
      expect(SynoException.fromCode(404).otpRejected, isTrue);
      expect(SynoException.fromCode(403).otpRejected, isFalse);
    });

    test('登录 URL 透传 otp_code 与设备令牌', () {
      final url = buildSynoUrl(
        host: '192.168.1.10',
        cgi: SynoEndpoints.authCgi,
        https: true,
        query: <String, String?>{
          'api': SynoApi.auth,
          'version': '6',
          'method': 'login',
          'otp_code': '123456',
          'enable_device_token': 'yes',
          'device_name': 'SynoCam iOS',
        },
      );
      expect(url.contains('otp_code=123456'), isTrue);
      expect(url.contains('enable_device_token=yes'), isTrue);
      expect(url.contains('device_name=SynoCam'), isTrue);
    });

    test('空 otp_code 被剔除，信任设备登录不带验证码', () {
      final url = buildSynoUrl(
        host: '192.168.1.10',
        cgi: SynoEndpoints.authCgi,
        https: true,
        query: <String, String?>{
          'api': SynoApi.auth,
          'method': 'login',
          'otp_code': null,
          'device_id': 'DID-1',
        },
      );
      expect(url.contains('otp_code'), isFalse);
      expect(url.contains('device_id=DID-1'), isTrue);
    });
  });

  group('Camera 字段别名映射', () {
    test('SS 多版本字段兼容解析', () {
      final cams = Camera.listFromData(<String, dynamic>{
        'cameras': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 1,
            'newName': '前门',
            'camModel': 'BC500',
            'ip': '192.168.1.101',
            'status': 1,
            'enabled': 1,
            'ptz': 1,
          },
          <String, dynamic>{'cameraId': 2, 'name': '车库', 'enabled': 0},
        ],
      });
      expect(cams.length, 2);
      expect(cams[0].name, '前门');
      expect(cams[0].ptzCapable, isTrue);
      expect(cams[0].isOnline, isTrue);
      expect(cams[1].isOnline, isFalse);
    });

    test('copyWith 只覆盖指定字段', () {
      const c = Camera(id: 1, name: 'A', quality: '4MP');
      final c2 = c.copyWith(name: 'B');
      expect(c2.name, 'B');
      expect(c2.quality, '4MP');
      expect(c2.id, 1);
    });
  });

  group('FeatureFlags', () {
    test('默认值 / 未登记 key 安全默认', () {
      final f = FeatureFlags();
      expect(f.isEnabled('live_h265_hardware_decode_enabled'), isTrue);
      expect(f.isEnabled('notification_push_v2_enabled'), isFalse);
      expect(f.isEnabled('unknown_key'), isFalse);
    });

    test('远程值覆盖本地默认', () {
      final f = FeatureFlags(
          remote: (k) => k == 'notification_push_v2_enabled' ? true : null);
      expect(f.isEnabled('notification_push_v2_enabled'), isTrue);
    });
  });
}
