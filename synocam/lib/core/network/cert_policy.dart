// HTTPS 证书策略：群晖 NAS 常用自签证书，默认严格校验会导致画面/接口全部失败。
// 由用户在「设置」里显式开启后才放宽校验；对 Dio 与 Image.network 同时生效。
import 'dart:io';

class _AllowBadCertOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) => true;
    return client;
  }
}

/// true = 允许自签/不受信证书（仅用于用户自有 NAS，需显式开启）。
/// false = 使用系统默认严格校验。
void applyCertificatePolicy(bool allowUntrusted) {
  HttpOverrides.global = allowUntrusted ? _AllowBadCertOverrides() : null;
}
