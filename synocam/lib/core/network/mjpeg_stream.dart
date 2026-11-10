// 纯 Dart MJPEG（multipart/x-mixed-replace）流解析与客户端。
//
// SS 的 VideoStreaming/Stream 返回连续 JPEG 帧流。Flutter 的 Image.network
// 不支持该 MIME，本模块用 dart:io HttpClient 逐块读流并切出每一帧，
// 供 App 内「连续实时画面」与「回放画面」复用，无需原生播放器插件。
//
// 证书策略：不在此处覆盖 badCertificateCallback，统一由
// core/network/cert_policy.dart 的 HttpOverrides.global 决定，
// 保证「信任自签名证书」开关对所有网络链路一致生效。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class MjpegException implements Exception {
  MjpegException(this.message);
  final String message;
  @override
  String toString() => 'MjpegException: $message';
}

/// 在字节列表中查找子序列，返回起始下标，未找到返回 -1。
int indexOfBytes(List<int> haystack, List<int> needle, [int start = 0]) {
  if (needle.isEmpty) return start;
  if (start < 0) start = 0;
  for (var i = start; i <= haystack.length - needle.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

bool _isJpeg(List<int> b) =>
    b.length > 2 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

/// 从 Content-Type 头提取 boundary（支持带引号与参数顺序变化）。
String boundaryFrom(String contentType) {
  final m = RegExp(r'boundary\s*=\s*"?([^";\s]+)"?', caseSensitive: false)
      .firstMatch(contentType);
  return m?.group(1) ?? '';
}

/// 把 multipart 流切成一帧帧 JPEG。
/// 优先按 Content-Length 精确切帧；无该头时退化为按下一个 boundary 切分。
Stream<Uint8List> parseMjpegFrames(
    Stream<List<int>> input, String boundary) async* {
  final delimiter = latin1.encode('--$boundary');
  final headerEndMark = <int>[13, 10, 13, 10]; // \r\n\r\n
  final acc = <int>[];

  await for (final chunk in input) {
    acc.addAll(chunk);
    var progressed = true;
    while (progressed) {
      progressed = false;
      final start = indexOfBytes(acc, delimiter);
      if (start < 0) {
        // 只保留末尾可能是 delimiter 前缀的部分。
        if (acc.length > delimiter.length) {
          acc.removeRange(0, acc.length - delimiter.length);
        }
        break;
      }
      if (start > 0) acc.removeRange(0, start); // 丢弃 preamble
      final he = indexOfBytes(acc, headerEndMark, delimiter.length);
      if (he < 0) break; // 头还没收齐
      final header = latin1.decode(
          acc.sublist(delimiter.length, he),
          allowInvalid: true);
      final dataStart = he + 4;
      final lenMatch = RegExp(r'Content-Length\s*:\s*(\d+)',
              caseSensitive: false)
          .firstMatch(header);
      if (lenMatch != null) {
        final len = int.tryParse(lenMatch.group(1)!) ?? 0;
        if (len <= 0) {
          acc.removeRange(0, dataStart);
          progressed = true;
          continue;
        }
        if (acc.length < dataStart + len) break; // 帧数据未收齐
        final frame =
            Uint8List.fromList(acc.sublist(dataStart, dataStart + len));
        acc.removeRange(0, dataStart + len);
        progressed = true;
        if (_isJpeg(frame)) yield frame;
      } else {
        final next = indexOfBytes(acc, delimiter, dataStart);
        if (next < 0) break;
        var end = next;
        while (end > dataStart &&
            (acc[end - 1] == 13 || acc[end - 1] == 10)) {
          end--;
        }
        if (end > dataStart) {
          final frame = Uint8List.fromList(acc.sublist(dataStart, end));
          if (_isJpeg(frame)) yield frame;
        }
        acc.removeRange(0, next);
        progressed = true;
      }
    }
    // 防御：异常流导致缓冲区无限膨胀。
    if (acc.length > 8 * 1024 * 1024) acc.clear();
  }
}

/// 无 multipart 封装时，按 JPEG SOI/EOI 标记切帧。
Stream<Uint8List> parseRawJpegFrames(Stream<List<int>> input) async* {
  final acc = <int>[];
  await for (final chunk in input) {
    acc.addAll(chunk);
    while (true) {
      final soi = indexOfBytes(acc, <int>[0xFF, 0xD8]);
      if (soi < 0) {
        if (acc.length > 2) acc.removeRange(0, acc.length - 2);
        break;
      }
      final eoi = indexOfBytes(acc, <int>[0xFF, 0xD9], soi + 2);
      if (eoi < 0) {
        if (soi > 0) acc.removeRange(0, soi);
        break;
      }
      final frame = Uint8List.fromList(acc.sublist(soi, eoi + 2));
      acc.removeRange(0, eoi + 2);
      yield frame;
    }
    if (acc.length > 8 * 1024 * 1024) acc.clear();
  }
}

/// SS MJPEG 流客户端。以 stream 形式持续产出帧，调用方 cancel 即断开连接。
class MjpegStreamClient {
  MjpegStreamClient({required this.url, this.cookie = ''});

  final String url;
  final String cookie;

  Stream<Uint8List> frames() async* {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 12);
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme) {
        throw MjpegException('直播流地址无效');
      }
      final req = await client.getUrl(uri);
      if (cookie.isNotEmpty) req.headers.set('Cookie', cookie);
      req.headers.set('User-Agent', 'SynoCam/1.0');
      req.headers.set('Accept', 'multipart/x-mixed-replace, image/jpeg, */*');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        final hint = await resp
            .transform(latin1.decoder)
            .take(1)
            .join();
        throw MjpegException('HTTP ${resp.statusCode}'
            '${hint.isEmpty ? '' : ' · ${hint.substring(0, hint.length > 90 ? 90 : hint.length)}'}');
      }
      final ct = resp.headers.value('content-type') ?? '';
      final boundary = boundaryFrom(ct);
      if (boundary.isNotEmpty) {
        yield* parseMjpegFrames(resp, boundary);
      } else {
        yield* parseRawJpegFrames(resp);
      }
    } finally {
      client.close(force: true);
    }
  }
}
