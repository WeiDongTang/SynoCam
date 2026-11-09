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
