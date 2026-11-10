// 核心协议层单元测试（CI: flutter test）。
// 覆盖：URL 构造、响应/错误码解析、Camera 字段别名映射、功能开关默认与覆盖。
import 'package:flutter_test/flutter_test.dart';

import 'package:synocam/core/config/feature_flags.dart';
import 'package:synocam/core/network/mjpeg_stream.dart';
import 'package:synocam/core/network/syno_api.dart';
import 'package:synocam/data/models/camera.dart';
import 'package:synocam/data/models/media.dart';
import 'package:synocam/data/models/syno_session.dart';

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

  group('真实 API 链路（无演示数据）', () {
    test('SS 录像事件 method 为 Query，直播流 API 名正确', () {
      expect(SynoMethod.queryEvents, 'Query');
      expect(SynoMethod.queryApiInfo, 'query');
      expect(SynoApi.videoStream,
          'SYNO.SurveillanceStation.Stream.VideoStreaming');
    });

    test('SYNO.API.Info 动态版本发现', () {
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
      expect(info['SYNO.SurveillanceStation.Camera']!.effectiveVersion(), 9);
      expect(info['SYNO.SurveillanceStation.Event']!.effectiveVersion(), 1);
      expect(info['SYNO.SurveillanceStation.Camera']!.cgi, '/webapi/entry.cgi');
      expect(SynoEndpoints.cgiFromPath(null), SynoEndpoints.entryCgi);
    });

    test('StmKey 从嵌套结构与直播路径中真实解析', () {
      final a = Camera.fromSynoJson(<String, dynamic>{
        'id': 1,
        'name': '前门',
        'streamInfo': <String, dynamic>{'stmKey': 'ABC123456789'},
      });
      expect(a.canStream, isTrue);
      expect(a.stmKey, 'ABC123456789');

      final b = Camera.fromSynoJson(<String, dynamic>{
        'id': 2,
        'name': '车库',
        'mjpegHttpPath':
            'http://nas:5000/webapi/entry.cgi?api=SYNO.SurveillanceStation.Stream.VideoStreaming&method=Stream&StmKey="XYZ987654321"',
      });
      expect(b.canStream, isTrue);
      expect(const Camera(id: 3, name: '无凭证').canStream, isFalse);
    });

    test('Event/Query 真实字段映射为录像与通知', () {
      final r = Recording.fromEventJson(<String, dynamic>{
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
      expect(r.durationSeconds, 60);
      expect(r.locked, isTrue);
      expect(r.eventType, '移动侦测');
      expect(r.cameraName, '前门');
      expect(SurveillanceEvent.fromRecording(r).type, 'motion');
    });

    test('不支持的接口错误码用于真实回退，异常携带错误码', () {
      expect(SynoErrorCode.isUnsupported(102), isTrue);
      expect(SynoErrorCode.isUnsupported(103), isTrue);
      expect(SynoErrorCode.isUnsupported(400), isFalse);
      expect(
          SynoException.fromCode(102).diagnostic.contains('错误码 102'), isTrue);
    });
  });

  group('流端点鉴权与媒体字节（修复 HTTP 465 画面加载失败）', () {
    test('会话 Cookie 同时携带 id=<sid> 与 did=<设备令牌>', () {
      const s = SynoSession(
          sid: 'SID-9',
          host: 'nas',
          account: 'admin',
          https: true,
          port: 5001,
          did: 'DID-7');
      expect(s.cookieHeader, 'id=SID-9; did=DID-7');
      expect(
          SynoSession.fromJson(s.toJson()).cookieHeader, 'id=SID-9; did=DID-7');
      expect(
          const SynoSession(
                  sid: 'S', host: 'nas', account: 'a', https: false, port: 5000)
              .cookieHeader,
          'id=S');
    });

    test('识别真实 JPEG/PNG，拒绝 DSM 的 JSON 错误响应', () {
      expect(MediaBytes.isImage(<int>[0xFF, 0xD8, 0xFF, 0xE0, 0]), isTrue);
      expect(MediaBytes.isImage(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D]), isTrue);
      expect(MediaBytes.isImage(<int>[0x7B, 0x22, 0x65, 0x72]), isFalse);
      expect(MediaBytes.isImage(<int>[0xFF, 0xD8]), isFalse);
      expect(MediaBytes.looksLikeJsonError('{"error":{"code":400}}'.codeUnits),
          isTrue);
      expect(MediaBytes.looksLikeJsonError(<int>[]), isTrue);
      expect(
          MediaBytes.looksLikeJsonError(
              <int>[0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]),
          isFalse);
    });

    test('按文件头推断录像容器扩展名', () {
      expect(
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
          ]),
          '.mp4');
      expect(MediaBytes.extensionFor(<int>[0x1A, 0x45, 0xDF, 0xA3]), '.mkv');
      expect(MediaBytes.extensionFor(<int>[0x52, 0x49, 0x46, 0x46]), '.avi');
      expect(MediaBytes.extensionFor(<int>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
          '.mp4');
    });
  });

  group('MJPEG 流解析（App 内连续画面 / 回放）', () {
    test('boundary 提取与字节子序列定位', () {
      expect(boundaryFrom('multipart/x-mixed-replace; boundary=myBoundary'),
          'myBoundary');
      expect(boundaryFrom('multipart/x-mixed-replace; boundary="quoted-b"'),
          'quoted-b');
      expect(boundaryFrom('image/jpeg'), '');
      expect(indexOfBytes(<int>[1, 2, 3, 4, 5], <int>[3, 4]), 2);
      expect(indexOfBytes(<int>[1, 2, 3], <int>[9]), -1);
      expect(indexOfBytes(<int>[1, 2, 1, 2], <int>[1, 2], 1), 2);
    });

    test('multipart 流按 Content-Length 切出完整 JPEG 帧', () async {
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
      expect(frames.length, 2);
      expect(frames.first.length, 5);
      expect(frames.first[0], 0xFF);
      expect(frames.last[4], 0x02);
    });

    test('裸 JPEG 流按 SOI/EOI 切帧', () async {
      final raw = <int>[
        0xFF,
        0xD8,
        0xFF,
        0xAA,
        0xFF,
        0xD9,
        0xFF,
        0xD8,
        0xFF,
        0xBB,
        0xFF,
        0xD9,
      ];
      final frames = await parseRawJpegFrames(
          Stream<List<int>>.fromIterable(<List<int>>[raw])).toList();
      expect(frames.length, 2);
      expect(frames[0][3], 0xAA);
      expect(frames[1][3], 0xBB);
    });
  });

  group('时间轴拖动 / App 内片段回放', () {
    final day = DateTime(2024, 5, 1);
    final clip = Recording(
      id: 'c1',
      cameraId: 1,
      cameraName: '前门',
      startTime: day.add(const Duration(hours: 10)),
      durationSeconds: 600,
    );

    test('24 小时与 [0,1] 双向换算', () {
      expect(TimelineMath.secondsPerDay, 86400);
      expect(TimelineMath.fractionOf(day.add(const Duration(hours: 6)), day),
          closeTo(0.25, 1e-9));
      expect(TimelineMath.timeAt(0.5, day).hour, 12);
      expect(TimelineMath.timeLabel(DateTime(2024, 5, 1, 9, 5, 3)), '09:05:03');
      expect(
          TimelineMath.fractionOf(day.add(const Duration(days: 2)), day), 1.0);
      expect(
          TimelineMath.fractionOf(day.subtract(const Duration(hours: 5)), day),
          0.0);
    });

    test('拖动定位命中 / 回退到最近真实片段', () {
      expect(clip.endTime, day.add(const Duration(hours: 10, minutes: 10)));
      expect(
          TimelineMath.clipAt(<Recording>[clip],
              day.add(const Duration(hours: 10, minutes: 5))),
          clip);
      expect(
          TimelineMath.clipAt(
              <Recording>[clip], day.add(const Duration(hours: 11))),
          isNull);
      expect(
          TimelineMath.nearestClip(
              <Recording>[clip], day.add(const Duration(hours: 23))),
          clip);
      expect(TimelineMath.nearestClip(<Recording>[], day), isNull);
    });
  });

  group('会话失效闭环（HTTP 465 / 登录页 HTML）', () {
    test('465 / 150 触发重新登录，文案不再误报地址问题', () {
      expect(SynoErrorCode.portalAuthRequired, 465);
      expect(SynoErrorCode.ipMismatch, 150);
      expect(SynoException.fromCode(465).needsReLogin, isTrue);
      expect(SynoException.fromCode(150).needsReLogin, isTrue);
      expect(SynoErrorCode.describe(465).contains('重新登录'), isTrue);
      expect(SynoErrorCode.describe(465).contains('地址/端口'), isFalse);
    });

    test('465 + 登录页 HTML 归类为会话失效，404 网页不误判', () {
      final html = '<!DOCTYPE html><html><head>'
          '<meta name="viewport" content="width=device-width"></head>'
          '<body>Synology DSM login</body></html>';
      expect(classifyHttpResponse(465, html).needsReLogin, isTrue);
      expect(classifyHttpResponse(200, html).needsReLogin, isTrue);
      expect(classifyHttpResponse(465, html).code,
          SynoErrorCode.portalAuthRequired);
      final json465 =
          classifyHttpResponse(465, '{"success":false,"error":{"code":400}}');
      expect(json465.needsReLogin, isFalse);
      expect(json465.code, 400);
      final notFound = classifyHttpResponse(
          404, '<html><body><h1>404 Not Found</h1></body></html>');
      expect(notFound.needsReLogin, isFalse);
      expect(notFound.message.contains('地址/端口/HTTPS'), isTrue);
      expect(classifyHttpResponse(500, 'upstream error').needsReLogin, isFalse);
    });

    test('classifyFailure / needsReLoginError 覆盖异常与文本', () {
      expect(classifyFailure(SynoException.fromCode(465)).needsReLogin, isTrue);
      expect(classifyFailure(SynoException.fromCode(106)).needsReLogin, isTrue);
      expect(classifyFailure('登录会话已过期，请重新登录').needsReLogin, isTrue);
      expect(classifyFailure('HTTPS 证书不受信任').kind, FailureKind.certificate);
      expect(classifyFailure('连接超时，请检查地址与网络').kind, FailureKind.network);
      expect(classifyFailure(null).needsReLogin, isFalse);
      expect(needsReLoginError(SynoException.fromCode(465)), isTrue);
      expect(needsReLoginError('MjpegException: 登录会话已过期，请重新登录'), isTrue);
      expect(needsReLoginError('错误码 102'), isFalse);
    });

    test('普通 HTML / 业务错误不误判为会话失效', () {
      final webUi = '<!DOCTYPE html><html><head>'
          '<meta name="viewport" content="width=device-width"></head>'
          '<body><div id="surveillance-station">Loading...</div></body></html>';
      expect(classifyHttpResponse(200, webUi).needsReLogin, isFalse);
      expect(classifyHttpResponse(200, webUi).message.contains('地址/端口/HTTPS'),
          isTrue);
      expect(classifyHttpResponse(465, '').needsReLogin, isTrue);
      expect(classifyHttpResponse(465, '\xff\xd8\xff\xe0binary').needsReLogin,
          isFalse);
      expect(
          classifyFailure('NAS 返回业务错误码 400（HTTP 465）').needsReLogin, isFalse);
    });

    test('登录保护窗口：suppress 期间不踢出刚登录的会话', () {
      final guard = SessionExpiryGuard();
      expect(guard.shouldExpire(detected: true, hasSession: true), isTrue);
      guard.suppress();
      expect(guard.suppressed, isTrue);
      expect(guard.shouldExpire(detected: true, hasSession: true), isFalse);
      expect(
          guard.shouldExpire(
              detected: true, hasSession: true, authenticating: true),
          isFalse);
      guard.release();
      expect(guard.suppressed, isFalse);
      expect(guard.shouldExpire(detected: true, hasSession: true), isTrue);
      expect(guard.shouldExpire(detected: true, hasSession: false), isFalse);
      expect(guard.shouldExpire(detected: false, hasSession: true), isFalse);
    });

    test('地址端口错配 / 402 权限 / 登录宽限期 / 诊断脱敏', () {
      final mixed = buildSynoUrl(
        host: '192.168.1.10:5000',
        cgi: SynoEndpoints.authCgi,
        https: true,
        port: 5000,
        query: <String, String?>{'api': SynoApi.auth},
      );
      expect(mixed.startsWith('https://192.168.1.10:5000/'), isTrue);
      expect(mixed.contains('5000:5000'), isFalse);
      expect(SynoException.fromCode(402).needsReLogin, isFalse);
      expect(SynoException.fromCode(105).needsReLogin, isFalse);
      final g = SessionExpiryGuard();
      g.grantGrace(const Duration(minutes: 1));
      expect(g.suppressed, isTrue);
      expect(g.shouldExpire(detected: true, hasSession: true), isFalse);
      g.clearGrace();
      expect(g.suppressed, isFalse);
      expect(g.shouldExpire(detected: true, hasSession: true), isTrue);
      final safe = sanitizeApiUrl(
          'http://192.168.1.10:5000/webapi/auth.cgi?account=admin'
          '&passwd=p%40ss&otp_code=123456&_sid=ABC');
      expect(safe.contains('p%40ss'), isFalse);
      expect(safe.contains('123456'), isFalse);
      expect(safe.contains('ABC'), isFalse);
      expect(safe.contains('account=admin'), isTrue);
      expect(safe.contains('passwd='), isTrue);
    });

    test('两步验证输入留空不再阻塞登录提交', () {
      expect(normalizeOtp(null), isNull);
      expect(normalizeOtp(''), isNull);
      expect(normalizeOtp('   '), isNull);
      expect(normalizeOtp(' 123456 '), '123456');
      expect(normalizeOtp('123'), '123');
    });

    test('上次连接信息序列化往返且绝不含密码', () {
      const c = LastConnection(
          host: 'nas.naeeeo.com',
          account: 'naeeo',
          https: true,
          port: 5001,
          twoFactor: true,
          trustDevice: true);
      final c2 = LastConnection.fromJson(c.toJson());
      expect(c2.host, 'nas.naeeeo.com');
      expect(c2.account, 'naeeo');
      expect(c2.port, 5001);
      expect(c2.twoFactor, isTrue);
      expect(c2.trustDevice, isTrue);
      expect(c.toJson().containsKey('password'), isFalse);
      expect(c.isValid, isTrue);
      expect(
          const LastConnection(host: '', account: 'a', https: true, port: 5001)
              .isValid,
          isFalse);
    });
  });
}
