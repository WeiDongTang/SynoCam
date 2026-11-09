# i18n 资源

已生成 zh / en 的 ARB 资源。下一步：
1. `flutter pub add flutter_localizations`
2. MaterialApp 配置 localizationsDelegates 与 supportedLocales
3. 文案走 AppLocalizations.of(context)!.key，禁止硬编码
4. 伪本地化提前暴露截断/拼接问题
