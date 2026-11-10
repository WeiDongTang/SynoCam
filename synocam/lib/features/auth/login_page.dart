// 登录页：QuickConnect ID / IP / DDNS、HTTPS、端口、账号密码、两步验证（OTP）、
// 信任此设备（device token）、记住我。
//
// 对齐官方 DS Cam 登录基线，并按 Synology《DSM Login Web API Guide》实现完整
// 2FA 闭环：账号开启两步验证后，仅传密码会收到 403（需验证码），此时自动展开
// OTP 输入框；验证码错误为 404、强制 2FA 为 406。首次成功且勾选「信任此设备」
// 会保存 DSM 返回的 did，之后登录免验证码。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final _otpFocus = FocusNode();

  bool _https = true;
  bool _remember = true;
  bool _twoFactor = false; // 账号已开启两步验证（用户主动勾选 / 服务端 403 自动置真）
  bool _trustDevice = false;
  bool _obscure = true;
  bool _loading = false;
  String? _error;
  String? _hint; // 2FA 引导（蓝色提示，区别于红色错误）
  bool _otpRejected = false; // 上一次验证码被拒（404）

  @override
  void dispose() {
    _host.dispose();
    _account.dispose();
    _password.dispose();
    _port.dispose();
    _otp.dispose();
    _otpFocus.dispose();
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
      _hint = null;
    });
    try {
      await context.read<AppState>().login(
            host: _host.text,
            account: _account.text,
            password: _password.text,
            https: _https,
            port: _effectivePort(),
            otpCode: _twoFactor ? _otp.text.trim() : null,
            enableDeviceToken: _twoFactor && _trustDevice,
            deviceName: 'SynoCam iOS',
            remember: _remember,
          );
    } on SynoException catch (e) {
      if (e.needsOtp) {
        // 服务端要求两步验证：自动展开 OTP 框并聚焦，给出针对性引导。
        setState(() {
          _twoFactor = true;
          _otpRejected = e.otpRejected;
          _hint = e.code == SynoErrorCode.otpRequired
              ? '该账号已开启两步验证，请输入验证器 App 生成的 6 位验证码后重新登录。'
              : e.code == SynoErrorCode.otpInvalid
                  ? '验证码错误或已过期，请等待验证器生成新验证码后重试。'
                  : '管理员要求此账号必须完成两步验证，请输入验证码。';
          _error = e.diagnostic;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _otpFocus.requestFocus();
        });
      } else {
        setState(() => _error = e.diagnostic);
      }
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
                  const SizedBox(height: 30),
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
                  const SizedBox(height: 6),
                  _switchTile(
                    '账号已开启两步验证（2FA）',
                    _twoFactor,
                    (v) => setState(() {
                      _twoFactor = v;
                      _hint = null;
                      _error = null;
                      if (v) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) _otpFocus.requestFocus();
                        });
                      }
                    }),
                    icon: AppIcons.shield,
                  ),
                  if (_twoFactor) ...<Widget>[
                    const SizedBox(height: 6),
                    if (_hint != null) _hintBanner(_hint!),
                    const SizedBox(height: 10),
                    _otpField(),
                    _switchTile(
                      '信任此设备（下次免验证码）',
                      _trustDevice,
                      (v) => setState(() => _trustDevice = v),
                      icon: AppIcons.checkCircle,
                    ),
                  ],
                  _switchTile(
                      '使用 HTTPS',
                      _https,
                      (v) => setState(() {
                            _https = v;
                            _port.clear();
                          })),
                  _switchTile(
                      '记住我', _remember, (v) => setState(() => _remember = v)),
                  _certTile(),
                  if (_error != null && !_twoFactor) _errorBanner(_error!),
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

  /// 群晖自签证书会导致登录请求直接握手失败；开启后对 Dio 与画面请求同时生效。
  Widget _certTile() {
    final state = context.watch<AppState>();
    return _switchTile(
      '信任自签名 HTTPS 证书（自有 NAS）',
      state.prefs.allowUntrustedCert,
      (v) => state.setAllowUntrustedCert(v),
      icon: AppIcons.shield,
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

  Widget _otpField() => TextFormField(
        controller: _otp,
        focusNode: _otpFocus,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        onFieldSubmitted: (_) {
          if (!_loading) _submit();
        },
        maxLength: 6,
        autofillHints: const <String>[AutofillHints.oneTimeCode],
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
        ],
        validator: (v) {
          if (!_twoFactor) return null;
          final s = v?.trim() ?? '';
          if (s.isEmpty) return '请输入 6 位两步验证验证码';
          if (s.length != 6) return '验证码应为 6 位数字';
          return null;
        },
        decoration: InputDecoration(
          labelText: '两步验证验证码（6 位）',
          hintText: '000000',
          counterText: '',
          errorStyle: TextStyle(
              color: _otpRejected ? AppColors.red : null, fontSize: 11),
          prefixIcon: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: AppIcon(AppIcons.shield, size: 18),
          ),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 42, minHeight: 42),
        ),
      );

  Widget _switchTile(String label, bool value, ValueChanged<bool> onChanged,
          {IconData? icon}) =>
      Row(
        children: <Widget>[
          Switch(value: value, onChanged: onChanged),
          const SizedBox(width: 4),
          if (icon != null) ...<Widget>[
            AppIcon(icon, size: 14, color: AppColors.sub),
            const SizedBox(width: 5),
          ],
          Expanded(
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
        ],
      );

  Widget _hintBanner(String msg) => Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: AppColors.blueSoft,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const AppIcon(AppIcons.info, size: 17, color: AppColors.blue),
            const SizedBox(width: 8),
            Expanded(
              child: Text(msg,
                  style:
                      const TextStyle(fontSize: 11.5, color: AppColors.blue)),
            ),
          ],
        ),
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
