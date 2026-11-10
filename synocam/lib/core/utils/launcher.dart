// 外部链接打开工具：录像播放/下载、Surveillance Station 网页端。
// 只在确实需要系统播放器或网页端配置时才跳转，App 内不伪造成功。
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> openExternalUrl(BuildContext context, String url,
    {String? label}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) {
    _snack(context, '无效的链接：$url');
    return;
  }
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) _snack(context, '无法打开${label ?? '链接'}，可复制后在浏览器打开');
  } catch (e) {
    _snack(context, '打开失败：$e');
  }
}

Future<void> copyToClipboard(BuildContext context, String text,
    {String label = '链接已复制'}) async {
  // 使用 Flutter 内置 Clipboard，不引入额外插件。
  await Clipboard.setData(ClipboardData(text: text));
  _snack(context, label);
}

void _snack(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));
}
