import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:provider/provider.dart';

import 'core/theme/app_theme.dart';
import 'features/auth/login_page.dart';
import 'features/shell/app_shell.dart';
import 'state/app_state.dart';

class SynoCamApp extends StatelessWidget {
  const SynoCamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SynoCam · 群晖监控',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Consumer<AppState>(
        builder: (context, state, _) {
          // bootstrap 进行中先显示启动画面，避免登录页闪现。
          if (!state.bootstrapped) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (state.isLoggedIn) return const AppShell();
          return const LoginPage();
        },
      ),
    );
  }
}
