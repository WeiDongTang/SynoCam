// Aurora 浅色主题（对齐定稿 A）：iOS 系统蓝 + 大留白 + 分组卡片。
// 同时提供深色变体，供「首页模式 / 夜间」等场景使用。
//
// 目标 SDK：Flutter >= 3.22 / Dart >= 3.5（WidgetState* / CardThemeData 等 API）。
// pubspec.yaml 与 .github/workflows/ci.yml 均 pin 到该基线，避免跨版本编译失败。
import 'package:flutter/material.dart';
import 'app_colors.dart';

class AppTheme {
  AppTheme._();

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final base = ThemeData(brightness: brightness, useMaterial3: true);
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.blue,
      brightness: brightness,
      primary: AppColors.blue,
      error: AppColors.red,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark ? const Color(0xFF0F1116) : AppColors.bg,
      appBarTheme: AppBarTheme(
        elevation: 0,
        centerTitle: true,
        backgroundColor: Colors.transparent,
        foregroundColor: dark ? Colors.white : AppColors.ink,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: dark ? Colors.white : AppColors.ink,
        ),
        iconTheme: const IconThemeData(color: AppColors.blue),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dark ? const Color(0xFF161920) : AppColors.card,
        indicatorColor: AppColors.blueSoft,
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 10,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected
                ? AppColors.blue
                : (dark ? Colors.white54 : AppColors.faint),
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 22,
            color: selected
                ? AppColors.blue
                : (dark ? Colors.white54 : AppColors.faint),
          );
        }),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: dark ? const Color(0xFF1A1D24) : AppColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        margin: EdgeInsets.zero,
      ),
      dividerTheme: DividerThemeData(
        color: dark ? Colors.white12 : AppColors.lineSoft,
        space: 0,
        thickness: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF22262F) : const Color(0x21767C88),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        hintStyle: TextStyle(color: AppColors.faint, fontSize: 13),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(Colors.white),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? AppColors.green
                : AppColors.toggleOff),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: dark ? Colors.white : AppColors.ink,
        displayColor: dark ? Colors.white : AppColors.ink,
      ),
    );
  }
}
