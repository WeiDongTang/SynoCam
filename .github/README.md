# 移动 CI/CD 配置

平台: both ｜ 服务: github

## 需要配置的密钥（Secrets / Variables）
- Android: `ANDROID_KEYSTORE_B64`(base64 后的签名密钥)、`ANDROID_KEYSTORE_PASS`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASS`
- iOS: Fastlane Match 证书仓库密码 `MATCH_PASSWORD`、Apple ID `FASTLANE_APPLE_ID`/`FASTLANE_PASSWORD`、`IOS_SCHEME`

## 本地验证
```
bundle install
bundle exec fastlane both_test
```
## 上架
- `bundle exec fastlane both_beta`  → 内部/TestFlight
- `bundle exec fastlane both_release` → 商店全量（需先在商店后台建好应用与版本）
