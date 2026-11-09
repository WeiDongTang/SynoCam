# Supabase 接入

## 通用
- URL 与 anon key 来自项目 API 设置；写入远程配置，勿硬编码
- Auth: email/手机/OAuth；Realtime: 订阅表变更

## Flutter (pubspec.yaml)
supabase_flutter: ^2.4.0
// Supabase.initialize(url: , anonKey: )

## Android (build.gradle)
implementation 'io.supabase:gotrue-kt:2.10.0'
implementation 'io.supabase:postgrest-kt:2.10.0'

## iOS (Podfile)
pod 'Supabase', '~> 2.4.0'
