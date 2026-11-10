// 登录会话：保存 DSM 返回的 SID，后续所有 entry.cgi 请求都要带 _sid。
class SynoSession {
  const SynoSession({
    required this.sid,
    required this.host,
    required this.account,
    required this.https,
    required this.port,
    this.did,
  });

  final String sid;
  final String host;
  final String account;
  final bool https;
  final int port;
  final String? did;

  String get baseUrl => '${https ? 'https' : 'http'}://$host:$port';

  /// SS 二进制/流端点（GetSnapshot、VideoStreaming/Stream）要求的会话 Cookie。
  /// JSON API 用 _sid query 即可，但流端点缺此 Cookie 会被 DSM 以 HTTP 465 +
  /// {"error":{"code":400}} 拒绝——这正是「画面加载失败」的根因。
  /// 登录返回的 did（设备令牌）在启用 2FA/记住设备时存在，需一并带上。
  String get cookieHeader {
    final parts = <String>['id=$sid'];
    if (did != null && did!.isNotEmpty) parts.add('did=$did');
    return parts.join('; ');
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sid': sid,
        'host': host,
        'account': account,
        'https': https,
        'port': port,
        'did': did,
      };

  factory SynoSession.fromJson(Map<String, dynamic> j) => SynoSession(
        sid: j['sid'] as String,
        host: j['host'] as String,
        account: j['account'] as String,
        https: j['https'] as bool? ?? false,
        port: j['port'] as int? ?? 5000,
        did: j['did'] as String?,
      );
}

/// 上次成功登录的连接参数（不含密码，绝不持久化密码）。
/// 会话失效回到登录页时用于预填，让用户只需重输密码（+ 验证码），
/// 不必重新敲一遍 DDNS / 端口 / 账号；纯 Dart，便于自检覆盖序列化往返。
class LastConnection {
  const LastConnection({
    required this.host,
    required this.account,
    required this.https,
    required this.port,
    this.twoFactor = false,
    this.trustDevice = false,
  });

  final String host;
  final String account;
  final bool https;
  final int port;
  final bool twoFactor;
  final bool trustDevice;

  bool get isValid => host.trim().isNotEmpty && account.trim().isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'host': host,
        'account': account,
        'https': https,
        'port': port,
        'twoFactor': twoFactor,
        'trustDevice': trustDevice,
      };

  factory LastConnection.fromJson(Map<String, dynamic> j) => LastConnection(
        host: j['host'] as String? ?? '',
        account: j['account'] as String? ?? '',
        https: j['https'] as bool? ?? true,
        port: j['port'] as int? ?? 5001,
        twoFactor: j['twoFactor'] as bool? ?? false,
        trustDevice: j['trustDevice'] as bool? ?? false,
      );
}
