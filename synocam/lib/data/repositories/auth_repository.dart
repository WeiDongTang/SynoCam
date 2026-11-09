// 认证仓储：登录/登出 + 会话与「信任此设备」令牌持久化（凭据走安全存储）。
import '../../core/network/syno_client.dart';
import '../../core/storage/secure_store.dart';
import '../models/syno_session.dart';

class AuthRepository {
  AuthRepository(this._client, this._store);

  final SynoClient _client;
  final SecureStore _store;

  /// 读取该 NAS+账号已保存的设备令牌（用于免二次验证登录）。
  Future<String?> deviceId(String host, String account) =>
      _store.readDeviceId(host, account);

  Future<SynoSession> login({
    required String host,
    required String account,
    required String password,
    bool https = false,
    int? port,
    String? otpCode,
    bool enableDeviceToken = false,
    String? deviceName,
    bool remember = true,
  }) async {
    // 已信任此设备时，带 device_id 即可免验证码；否则用用户输入的 otp_code。
    final savedDid = await _store.readDeviceId(host, account);
    final session = await _client.login(
      host: host,
      account: account,
      password: password,
      https: https,
      port: port,
      otpCode: otpCode,
      enableDeviceToken: enableDeviceToken,
      deviceId: savedDid,
      deviceName: deviceName,
    );
    // DSM 在 enable_device_token=yes 时返回 did；保存供后续免验证登录。
    if (session.did != null && session.did!.isNotEmpty) {
      await _store.saveDeviceId(host, account, session.did!);
    }
    if (remember) {
      await _store.saveSession(session);
      await _store.saveCredentials(account, password);
    }
    return session;
  }

  Future<void> logout() async {
    await _client.logout();
    await _store.clear();
  }

  /// 冷启动恢复会话（记住我）。失败返回 null，UI 进入登录页。
  Future<SynoSession?> restore() async {
    final saved = await _store.readSession();
    if (saved == null) return null;
    // 把 SID 注入回 client，否则恢复后的首个 API 调用会误判为「尚未登录」。
    _client.restoreSession(saved);
    // DSM SID 有有效期；恢复后首个请求若返回 106/107 由 UI 触发重新登录。
    return saved;
  }
}
