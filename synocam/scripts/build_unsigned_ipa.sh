#!/usr/bin/env bash
# SynoCam · 构建「未签名」 iOS IPA
#
# 用途：产出 build/ipa/SynoCam-unsigned.ipa（Payload/Runner.app 结构，未含签名/描述文件）。
# 该 ipa 不能直接安装到未越狱真机，仅用于：
#   - 用你自己的开发者证书/企业证书重签名后分发（adhoc / enterprise / development）
#   - 交给签名服务、越狱设备或 CI 归档
# 正式的 App Store 包请用 `flutter build ipa` + 签名（见 docs/store/ 与 .github/fastlane/Fastfile）。
#
# 前置条件（仅 macOS）：Xcode（含 Command Line Tools）、CocoaPods、Flutter 3.24.x。
# 用法：在 synocam/ 目录下执行 `bash scripts/build_unsigned_ipa.sh`
set -euo pipefail

echo "==> 0/5 环境检查"
if [ "$(uname -s)" != "Darwin" ]; then
  echo "::error:: iOS 构建必须在 macOS + Xcode 上进行（当前为 $(uname -s)）。"
  echo "          若你在 Linux/Windows，请改用 GitHub Actions 的 macOS runner 产出 ipa。"
  exit 1
fi
command -v flutter >/dev/null 2>&1 || { echo "::error:: 未找到 flutter"; exit 1; }
command -v xcodebuild >/dev/null 2>&1 || { echo "::error:: 未找到 Xcode / xcodebuild"; exit 1; }

echo "==> 1/5 安装依赖"
flutter pub get

echo "==> 2/5 生成本地化（app.dart 依赖 flutter_gen）"
flutter gen-l10n

echo "==> 3/5 生成 iOS 原生壳（若尚未生成）"
if [ ! -f ios/Runner.xcodeproj/project.pbxproj ]; then
  flutter create --platforms=ios --project-name synocam --org com.synocam .
fi

echo "==> 4/5 编译 iOS（不签名）"
flutter build ios --release --no-codesign

echo "==> 5/5 打包未签名 IPA"
APP=$(find build/ios -type d -name Runner.app -maxdepth 4 | head -n 1)
if [ -z "$APP" ]; then
  echo "::error:: 未找到 Runner.app，编译产物异常"; exit 1
fi
echo "    使用 app: $APP"
rm -rf build/ipa
mkdir -p build/ipa/Payload
cp -R "$APP" build/ipa/Payload/
find build/ipa/Payload -name '.DS_Store' -delete || true
( cd build/ipa && zip -qry SynoCam-unsigned.ipa Payload )
echo "==> 结构校验"
( cd build/ipa && unzip -l SynoCam-unsigned.ipa | head -n 15 )
echo "==> 完成"
ls -lh build/ipa/SynoCam-unsigned.ipa
echo "产物：$(pwd)/build/ipa/SynoCam-unsigned.ipa"
