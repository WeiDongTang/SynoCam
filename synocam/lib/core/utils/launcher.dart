// 外部链接打开工具：录像播放/下载、Surveillance Station 网页端。
// 只在确实需要系统播放器或网页端配置时才跳转，App 内不伪造成功。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> openExternalUrl(BuildContext context, String url,
    {String? label}) async {
  // 在 await 之前取出 messenger，避免跨异步间隙继续使用 BuildContext。
  final messenger = ScaffoldMessenger.of(context);
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) {
    _snack(messenger, '无效的链接：$url');
    return;
  }
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) _snack(messenger, '无法打开${label ?? '链接'}，可复制后在浏览器打开');
  } catch (e) {
    _snack(messenger, '打开失败：$e');
  }
}

Future<void> copyToClipboard(BuildContext context, String text,
    {String label = '链接已复制'}) async {
  final messenger = ScaffoldMessenger.of(context);
  await Clipboard.setData(ClipboardData(text: text));
  _snack(messenger, label);
}

void _snack(ScaffoldMessengerState messenger, String msg) {
  messenger.showSnackBar(SnackBar(content: Text(msg)));
}
