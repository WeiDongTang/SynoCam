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
    return Consumer<AppState>(
      builder: (context, rootState, _) => MaterialApp(
        // 会话失效（已登录 → 未登录）时换 key，强制重建 Navigator，清空
        // 回放 / 单画面 / 编辑等所有 push 上去的二级页面，避免用户仍停留在
        // 报 465 的页面而看不到重新登录入口。
        key: ValueKey<String>(rootState.isLoggedIn ? 'shell' : 'login'),
        title: 'SynoCam',
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
      ),
    );
  }
}
