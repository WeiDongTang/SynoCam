// 应用级常量：连接默认值、超时、分页、登录参数等。
// 注意：账号/密码/SID 等敏感信息绝不写在此处，运行时由安全存储保存。
class AppConfig {
  AppConfig._();

  static const String appName = 'SynoCam';
  static const String appNameZh = '群晖监控';
  static const String sessionName = 'SurveillanceStation';
  static const String sidFormat = 'sid';

  /// DSM 登录使用的 API 版本（SYNO.API.Auth 最高支持 7，SS 常用 6）。
  static const int authVersion = 6;

  static const Duration connectTimeout = Duration(seconds: 12);
  static const Duration receiveTimeout = Duration(seconds: 20);
  static const Duration snapshotPollInterval = Duration(seconds: 2);

  static const int eventPageSize = 50;
  static const int recordingPageSize = 100;

  /// 支持的网格布局：单画面 / 1×2 / 2×2 / 3×3。
  static const List<int> gridLayouts = <int>[1, 2, 4, 9];

  /// 回放倍速档位（对齐官方 DS Cam 0.25x–5x）。
  static const List<double> playbackSpeeds = <double>[
    0.25,
    0.5,
    1.0,
    2.0,
    4.0,
    5.0
  ];
}
