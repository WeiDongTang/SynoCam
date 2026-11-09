// 统一图标渲染组件。
//
// 所有页面必须通过 AppIcon / AppIcons 取图标，禁止散写 Icon(Icons.xxx) 或 emoji。
// 固定 24 网格尺寸 + 统一色，配合 AppIcons 的单一映射表，从根上避免
// 「图标风格不一 / 大小参差 / 裁切错位」——这正是原型第 3 轮暴露的问题。
import 'package:flutter/material.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_icons.dart';

class AppIcon extends StatelessWidget {
  const AppIcon(
    this.icon, {
    super.key,
    this.size = 20,
    this.color,
  });

  final IconData icon;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => Icon(
        icon,
        size: size,
        color: color ?? AppColors.sub,
      );
}

/// 带圆角色块容器图标（对齐原型设置页 / 事件页的 .gi / .evi 样式）。
enum IconTone { blue, green, amber, red, neutral }

class BadgeIcon extends StatelessWidget {
  const BadgeIcon(
    this.icon, {
    super.key,
    this.tone = IconTone.blue,
    this.boxSize = 30,
    this.iconSize = 16,
  });

  final IconData icon;
  final IconTone tone;
  final double boxSize;
  final double iconSize;

  Color get _fg {
    switch (tone) {
      case IconTone.green:
        return AppColors.green;
      case IconTone.amber:
        return AppColors.amber;
      case IconTone.red:
        return AppColors.red;
      case IconTone.neutral:
        return AppColors.sub;
      case IconTone.blue:
        return AppColors.blue;
    }
  }

  Color get _bg {
    switch (tone) {
      case IconTone.green:
        return AppColors.iconBgGreen;
      case IconTone.amber:
        return AppColors.iconBgAmber;
      case IconTone.red:
        return AppColors.iconBgRed;
      case IconTone.neutral:
        return AppColors.iconBgNeutral;
      case IconTone.blue:
        return AppColors.iconBgBlue;
    }
  }

  @override
  Widget build(BuildContext context) => Container(
        width: boxSize,
        height: boxSize,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _bg,
          borderRadius: BorderRadius.circular(boxSize / 3.75),
        ),
        child: AppIcon(icon, size: iconSize, color: _fg),
      );
}

/// 便捷：按语义名取图标（用于数据驱动的列表，避免页面里写死 Icons）。
IconData iconForEventType(String type) {
  switch (type) {
    case 'motion':
    case 'alarm':
      return AppIcons.alert;
    case 'door':
      return AppIcons.door;
    case 'dva':
      return AppIcons.sparkles;
    case 'system':
      return AppIcons.cpu;
    default:
      return AppIcons.info;
  }
}
