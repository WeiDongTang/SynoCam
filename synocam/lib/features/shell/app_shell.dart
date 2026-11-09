// 应用主壳：底部 5 tab（实时 / 摄像机 / 录像 / 通知 / 设置），对齐定稿 A 原型。
import 'package:flutter/material.dart';

import '../../core/theme/app_icons.dart';
import '../cameras/cameras_page.dart';
import '../live/live_page.dart';
import '../notifications/notifications_page.dart';
import '../recordings/recordings_page.dart';
import '../settings/settings_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  static const List<Widget> _pages = <Widget>[
    LivePage(),
    CamerasPage(),
    RecordingsPage(),
    NotificationsPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const <NavigationDestination>[
          NavigationDestination(icon: Icon(AppIcons.live), label: '实时'),
          NavigationDestination(icon: Icon(AppIcons.cameras), label: '摄像机'),
          NavigationDestination(icon: Icon(AppIcons.recordings), label: '录像'),
          NavigationDestination(
              icon: Icon(AppIcons.notifications), label: '通知'),
          NavigationDestination(icon: Icon(AppIcons.settings), label: '设置'),
        ],
      ),
    );
  }
}
