# 安全与隐私合规审核清单

- [ ] 全站 HTTPS（TLS 1.2+）
- [ ] 敏感接口启用 SSL Pinning
- [ ] 令牌存 Keychain / EncryptedSharedPreferences，无明文
- [ ] 开启 R8/ProGuard 混淆，敏感逻辑下沉原生
- [ ] Root/越狱检测与防调试
- [ ] 密钥/域名不硬编码，走远程配置或 NDK
- [ ] 隐私政策可访问并说明收集目的与第三方共享
- [ ] 提供账号注销与数据导出
- [ ] 儿童/青少年：年龄分级、限制追踪与广告（iOS ATT）
- [ ] 依赖漏洞扫描 + 隐私合规扫描通过

> 出处：对应 references/*.md；提审前逐条核对。
