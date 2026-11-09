// Design Token：与 ui/index.html 定稿 A（Aurora 浅色原生）一一对应。
// 修改 UI 原型配色时，只需同步本文件，全 App 自动生效。
import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // 背景 / 卡片
  static const Color bg = Color(0xFFEDEEF1);
  static const Color card = Color(0xFFFFFFFF);
  static const Color cardAlt = Color(0xFFF7F8FA);

  // 文本
  static const Color ink = Color(0xFF15181E);
  static const Color sub = Color(0xFF6C7078);
  static const Color faint = Color(0xFF9A9EA6);

  // 分隔线
  static const Color line = Color(0x1312161E); // rgba(18,22,30,.075)
  static const Color lineSoft = Color(0x0B12161E); // rgba(18,22,30,.045)

  // 主色（iOS 系统蓝）
  static const Color blue = Color(0xFF1C6BF2);
  static const Color blueSoft = Color(0x1A1C6BF2); // rgba(28,107,242,.10)

  // 状态色
  static const Color green = Color(0xFF1BA36A);
  static const Color red = Color(0xFFE14B3F);
  static const Color amber = Color(0xFFD98A2B);

  // 图标底色（按状态）
  static const Color iconBgBlue = blueSoft;
  static const Color iconBgGreen = Color(0x211BA36A);
  static const Color iconBgAmber = Color(0x24D98A2B);
  static const Color iconBgRed = Color(0x21E14B3F);
  static const Color iconBgNeutral = Color(0x1F6C7078);

  static const Color toggleOff = Color(0xFFD8DBE1);
  static const Color deviceShell = Color(0xFFD9DCE2);
}
