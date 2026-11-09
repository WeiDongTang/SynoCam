// 登录页：QuickConnect ID / IP / DDNS、HTTPS、端口、账号密码、OTP、记住我。
// 对齐官方 DS Cam 的登录能力基线；凭据只经 AuthRepository 走安全存储。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config/app_config.dart';
import '../../core/network/syno_api.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_icons.dart';
import '../../state/app_state.dart';
import '../../widgets/app_icon.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _host = TextEditingController();
  final _account = TextEditingController();
  final _password = TextEditingController();
  final _port = TextEditingController();
  final _otp = TextEditingController();

  bool _https = true;
  bool _remember = true;
  bool _showOtp = false;
  bool _obscure = true;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _account.dispose();
    _password.dispose();
    _port.dispose();
    _otp.dispose();
    super.dispose();
  }

  int? _effectivePort() {
    final t = _port.text.trim();
    if (t.isEmpty) return null;
    return int.tryParse(t);
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await context.read<AppState>().login(
            host: _host.text,
            account: _account.text,
            password: _password.text,
            https: _https,
            port: _effectivePort(),
            otpCode: _showOtp && _otp.text.isNotEmpty ? _otp.text : null,
            remember: _remember,
          );
    } on SynoException catch (e) {
      // 需要两步验证时自动展开 OTP 输入框。
      if (e.code == SynoErrorCode.needTwoFactor ||
          e.code == SynoErrorCode.otpRequired) {
        setState(() => _showOtp = true);
      }
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _brand(),
                  const SizedBox(height: 34),
                  _field(
                    controller: _host,
                    label: 'QuickConnect ID / IP / DDNS',
                    icon: AppIcons.server,
                    hint: 'nas.example.com 或 192.168.1.10',
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? '请输入 NAS 地址' : null,
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _field(
                          controller: _account,
                          label: '账号',
                          icon: AppIcons.faceId,
                          hint: 'admin',
                          validator: (v) =>
                              (v == null || v.isEmpty) ? '请输入账号' : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 96,
                        child: _field(
                          controller: _port,
                          label: '端口',
                          icon: AppIcons.info,
                          hint: _https ? '5001' : '5000',
                          keyboard: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _field(
                    controller: _password,
                    label: '密码',
                    icon: AppIcons.lock,
                    hint: '••••••••',
                    obscure: _obscure,
                    suffix: IconButton(
                      icon: AppIcon(_obscure ? AppIcons.eye : AppIcons.mute,
                          size: 18),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                    validator: (v) => (v == null || v.isEmpty) ? '请输入密码' : null,
                  ),
                  if (_showOtp) ...<Widget>[
                    const SizedBox(height: 14),
                    _field(
                      controller: _otp,
                      label: '两步验证验证码',
                      icon: AppIcons.shield,
                      hint: '6 位 OTP',
                      keyboard: TextInputType.number,
                    ),
                  ],
                  const SizedBox(height: 8),
                  _switchTile(
                      '使用 HTTPS',
                      _https,
                      (v) => setState(() {
                            _https = v;
                            _port.clear();
                          })),
                  _switchTile(
                      '记住我', _remember, (v) => setState(() => _remember = v)),
                  if (_error != null) _errorBanner(_error!),
                  const SizedBox(height: 18),
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: _loading ? null : _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.blue,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(13)),
                      ),
                      child: _loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('登录',
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    '需要 DSM 7.x / Surveillance Station 9.x\n账号需具备 Surveillance Station 访问权限',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: AppColors.faint),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _brand() => Column(
        children: <Widget>[
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.blue,
              borderRadius: BorderRadius.circular(18),
              boxShadow: <BoxShadow>[
                BoxShadow(
                    color: AppColors.blue.withOpacity(.28),
                    blurRadius: 20,
                    offset: const Offset(0, 8)),
              ],
            ),
            child:
                const AppIcon(AppIcons.cameras, size: 32, color: Colors.white),
          ),
          const SizedBox(height: 16),
          const Text('群晖监控',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('SynoCam · ${AppConfig.appName}',
              style: TextStyle(fontSize: 12, color: AppColors.sub)),
        ],
      );

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hint,
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboard,
    String? Function(String?)? validator,
  }) =>
      TextFormField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboard,
        validator: validator,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: AppIcon(icon, size: 18),
          ),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 42, minHeight: 42),
          suffixIcon: suffix,
        ),
      );

  Widget _switchTile(String label, bool value, ValueChanged<bool> onChanged) =>
      Row(
        children: <Widget>[
          Switch(value: value, onChanged: onChanged),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      );

  Widget _errorBanner(String msg) => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.iconBgRed,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: <Widget>[
            const AppIcon(AppIcons.alert, size: 18, color: AppColors.red),
            const SizedBox(width: 8),
            Expanded(
              child: Text(msg,
                  style: const TextStyle(fontSize: 12, color: AppColors.red)),
            ),
          ],
        ),
      );
}
