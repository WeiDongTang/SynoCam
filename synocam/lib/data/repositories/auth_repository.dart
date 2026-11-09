// 认证仓储：登录/登出 + 会话持久化（凭据走安全存储，不落明文）。
import '../../core/network/syno_client.dart';
import '../../core/storage/secure_store.dart';
import '../models/syno_session.dart';

class AuthRepository {
  AuthRepository(this._client, this._store);

  final SynoClient _client;
  final SecureStore _store;

  Future<SynoSession> login({
    required String host,
    required String account,
    required String password,
    bool https = false,
    int? port,
    String? otpCode,
    bool remember = true,
  }) async {
    final session = await _client.login(
      host: host,
      account: account,
      password: password,
      https: https,
      port: port,
      otpCode: otpCode,
    );
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
