// 功能开关（Feature Flag）：本地默认值 + 可注入的远程覆盖。
// 纯 Dart、无外部依赖，便于灰度发布与一键回滚，也便于单元测试。
// 命名规范见同目录 FEATURE_FLAG_NAMING.md。

typedef RemoteFlagProvider = bool? Function(String key);

class FeatureFlags {
  FeatureFlags({RemoteFlagProvider? remote}) : _remote = remote;

  RemoteFlagProvider? _remote;

  /// 所有开关的本地默认值，集中登记，避免散落硬编码。
  static const Map<String, bool> defaults = <String, bool>{
    'live_h265_hardware_decode_enabled': true,
    'live_picture_in_picture_enabled': true,
    'live_smart_timeline_enabled': true,
    'camera_onboarding_qr_enabled': true,
    'notification_push_v2_enabled': false,
    'home_mode_geofence_enabled': true,
  };

  /// 远程值优先，未配置时回落本地默认；未登记的 key 一律 false（安全默认）。
  bool isEnabled(String key) {
    final remoteValue = _remote?.call(key);
    if (remoteValue != null) return remoteValue;
    return defaults[key] ?? false;
  }

  /// 供远程配置（Firebase Remote Config / 自建分流）热替换覆盖源。
  void attachRemote(RemoteFlagProvider provider) => _remote = provider;
}
