// 安全存储抽象：会话与凭据。
//
// 生产实现应替换为 flutter_secure_storage（iOS Keychain / Android Keystore），
// 这里提供「接口 + 内存实现」使纯 Dart 层可独立编译与测试，不引入平台插件依赖。
// 绝不把密码写进 SharedPreferences 明文 —— 那是常见审核红线（见 checklist-security.md）。
import '../../data/models/syno_session.dart';

class Credentials {
  const Credentials(this.account, this.password);
  final String account;
  final String password;
}

abstract class SecureStore {
  Future<void> saveSession(SynoSession session);
  Future<SynoSession?> readSession();
  Future<void> saveCredentials(String account, String password);
  Future<Credentials?> readCredentials();
  Future<void> clear();
}

/// 内存实现（默认，用于演示/测试生命周期内的会话）。
class InMemorySecureStore implements SecureStore {
  SynoSession? _session;
  String? _account;
  String? _password;

  @override
  Future<void> saveSession(SynoSession session) async => _session = session;

  @override
  Future<SynoSession?> readSession() async => _session;

  @override
  Future<void> saveCredentials(String account, String password) async {
    _account = account;
    _password = password;
  }

  @override
  Future<Credentials?> readCredentials() async {
    if (_account == null || _password == null) return null;
    return Credentials(_account!, _password!);
  }

  @override
  Future<void> clear() async {
    _session = null;
    _account = null;
    _password = null;
  }
}
