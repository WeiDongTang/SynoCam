// 统一图标系统（Single Source of Truth）。
//
// 背景：UI 原型第 3 轮曾出现「图标风格不统一 / 显示不全 / 错位」，根因是各页面
// 散写 emoji 与字符图标、SVG symbol 缺 viewBox 导致缩放错位。
// 这里用一张集中映射表把所有图标收敛到同一套 SF-Symbols 风格的 Material 线性图标，
// 并统一 24 网格 / 线宽 / 尺寸，任何页面只允许通过 AppIcons.xxx 取图标，
// 禁止在页面里散写 Icons.xxx 或 emoji，从架构层面杜绝同类问题再次出现。

import 'package:flutter/material.dart';

class AppIcons {
  AppIcons._();

  // ── 主导航（5 tab）──
  static const IconData live = Icons.grid_view_rounded;
  static const IconData cameras = Icons.videocam_rounded;
  static const IconData recordings = Icons.movie_rounded;
  static const IconData notifications = Icons.notifications_rounded;
  static const IconData settings = Icons.settings_rounded;

  // ── 通用操作 ──
  static const IconData add = Icons.add_rounded;
  static const IconData remove = Icons.remove_rounded;
  static const IconData search = Icons.search_rounded;
  static const IconData list = Icons.list_rounded;
  static const IconData tiles = Icons.apps_rounded;
  static const IconData chevron = Icons.chevron_right_rounded;
  static const IconData back = Icons.arrow_back_ios_rounded;
  static const IconData close = Icons.close_rounded;
  static const IconData refresh = Icons.refresh_rounded;
  static const IconData check = Icons.check_rounded;
  static const IconData checkCircle = Icons.check_circle_rounded;
  static const IconData more = Icons.more_horiz_rounded;
  static const IconData filter = Icons.filter_list_rounded;
  static const IconData edit = Icons.edit_rounded;
  static const IconData delete = Icons.delete_outline_rounded;
  static const IconData info = Icons.info_outline_rounded;
  static const IconData download = Icons.download_rounded;
  static const IconData eye = Icons.visibility_rounded;

  // ── 安全 / 设置 ──
  static const IconData lock = Icons.lock_rounded;
  static const IconData unlock = Icons.lock_open_rounded;
  static const IconData faceId = Icons.face_rounded;
  static const IconData airplay = Icons.airplay_rounded;
  static const IconData bolt = Icons.bolt_rounded;
  static const IconData pip = Icons.picture_in_picture_alt_rounded;
  static const IconData timeline = Icons.timeline_rounded;
  static const IconData license = Icons.card_membership_rounded;
  static const IconData moon = Icons.dark_mode_rounded;
  static const IconData shield = Icons.verified_user_rounded;
  static const IconData location = Icons.location_on_rounded;
  static const IconData wifi = Icons.wifi_rounded;
  static const IconData server = Icons.dns_rounded;

  // ── 单画面 / PTZ / 时间轴 ──
  static const IconData snapshot = Icons.photo_camera_rounded;
  static const IconData mic = Icons.mic_rounded;
  static const IconData mute = Icons.volume_off_rounded;
  static const IconData zoom = Icons.zoom_in_rounded;
  static const IconData target = Icons.my_location_rounded;
  static const IconData patrol = Icons.loop_rounded;
  static const IconData power = Icons.power_settings_new_rounded;
  static const IconData skipBack = Icons.skip_previous_rounded;
  static const IconData play = Icons.play_arrow_rounded;
  static const IconData pause = Icons.pause_rounded;
  static const IconData skipFwd = Icons.skip_next_rounded;
  static const IconData keyframe = Icons.animation_rounded;
  static const IconData up = Icons.keyboard_arrow_up_rounded;
  static const IconData down = Icons.keyboard_arrow_down_rounded;
  static const IconData left = Icons.keyboard_arrow_left_rounded;
  static const IconData right = Icons.keyboard_arrow_right_rounded;

  // ── 添加摄像头 ──
  static const IconData qr = Icons.qr_code_rounded;
  static const IconData discovery = Icons.radar_rounded;

  // ── 事件类型 ──
  static const IconData alert = Icons.warning_amber_rounded;
  static const IconData door = Icons.door_front_door_rounded;
  static const IconData cpu = Icons.memory_rounded;
  static const IconData sparkles = Icons.auto_awesome_rounded;
}
