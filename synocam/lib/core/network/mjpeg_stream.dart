// 纯 Dart MJPEG（multipart/x-mixed-replace）流解析与客户端。
//
// SS 的 VideoStreaming/Stream 返回连续 JPEG 帧流。Flutter 的 Image.network
// 不支持该 MIME，本模块用 dart:io HttpClient 逐块读流并切出每一帧，
// 供 App 内「连续实时画面」与「回放画面」复用，无需原生播放器插件。
//
// 性能要点（实时画面卡顿的根因）：
//  1. 旧实现每收到一个网络块都对整块累积缓冲区做朴素线性扫描，并用
//     removeRange(0, …) 搬移整块数组；1080p 每帧上百 KB 时会退化为 O(n²)。
//     现改为「游标式增量解析」：只搜新增区间，已消费字节不参与扫描，
//     累积到阈值才做一次紧凑化。
//  2. 每帧只做一次字节拷贝（旧实现 laint1 解码头 + sublist 帧共 2~3 次）。
//  3. MjpegStreamClient 支持 maxFps 限流：网络帧快于 UI 解码时主动丢帧，
//     不让帧在解码队列里堆积造成延迟累积与卡顿。
//
// 证书策略：不在此处覆盖 badCertificateCallback，统一由
// core/network/cert_policy.dart 的 HttpOverrides.global 决定，
// 保证「信任自签名证书」开关对所有网络链路一致生效。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'syno_api.dart';

class MjpegException implements Exception {
  MjpegException(this.message, {this.needsReLogin = false});
  final String message;

  /// 该错误是否为「登录会话已过期」，供调用方触发全局重新登录。
  final bool needsReLogin;

  @override
  String toString() => 'MjpegException: $message';
}

/// 在字节列表中查找子序列，返回起始下标，未找到返回 -1。
/// 针对首字节做快速跳过，避免对每个位置都进入内层比较。
int indexOfBytes(List<int> haystack, List<int> needle, [int start = 0]) {
  if (needle.isEmpty) return start;
  if (start < 0) start = 0;
  final first = needle[0];
  final last = haystack.length - needle.length;
  for (var i = start; i <= last; i++) {
    if (haystack[i] != first) continue;
    var ok = true;
    for (var j = 1; j < needle.length; j++) {
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

/// 增量字节队列：用游标 _head 标记有效数据起点，避免每帧 removeRange(0,…)
/// 造成的整块数组搬移；只在已消费字节足够多时做一次紧凑化。
class _ByteQueue {
  final List<int> _buf = <int>[];
  int _head = 0;

  int get length => _buf.length - _head;

  int operator [](int i) => _buf[_head + i];

  void addAll(List<int> chunk) => _buf.addAll(chunk);

  /// 从相对下标 [from] 开始查找 [needle]，返回相对下标；未找到返回 -1。
  int indexOf(List<int> needle, int from) {
    final abs = indexOfBytes(_buf, needle, _head + from);
    return abs < 0 ? -1 : abs - _head;
  }

  /// 取出 [start,end) 区间，只做一次拷贝。
  Uint8List take(int start, int end) =>
      Uint8List.fromList(_buf.sublist(_head + start, _head + end));

  /// 供头部解码使用的小段字节（头部通常 < 200B）。
  List<int> slice(int start, int end) =>
      _buf.sublist(_head + start, _head + end);

  void consume(int n) {
    if (n <= 0) return;
    _head += n;
    if (_head >= 65536 && _head * 2 >= _buf.length) compact();
  }

  void compact() {
    if (_head == 0) return;
    _buf.removeRange(0, _head);
    _head = 0;
  }

  void clear() {
    _buf.clear();
    _head = 0;
  }
}

/// 把 multipart 流切成一帧帧 JPEG。
///
/// 显式状态机：等待 boundary → 等待头部 → 等待帧数据 → 等待下一个
/// boundary。旧实现每收到一个块都从「找 boundary」重新开始，当无
/// Content-Length 时，跨块的帧数据会被误当成 preamble 丢弃；现在每个
/// part 的解析状态跨网络块保持，且搜索起点单调递增只扫新增区间。
Stream<Uint8List> parseMjpegFrames(
    Stream<List<int>> input, String boundary) async* {
  final delimiter = latin1.encode('--$boundary');
  final headerEndMark = <int>[13, 10, 13, 10]; // \r\n\r\n
  final q = _ByteQueue();

  const int waitDelimiter = 0;
  const int waitHeader = 1;
  const int waitFrame = 2;
  const int waitNextBoundary = 3;
  var state = waitDelimiter;
  var dataStart = 0;
  var frameLen = 0;
  var boundaryScan = 0;

  await for (final chunk in input) {
    q.addAll(chunk);
    var progressed = true;
    while (progressed) {
      progressed = false;
      switch (state) {
        case waitDelimiter:
          final s = q.indexOf(delimiter, 0);
          if (s < 0) {
            // 保留末尾可能是 delimiter 前缀的字节，丢弃其余噪声。
            if (q.length > delimiter.length) {
              q.consume(q.length - delimiter.length + 1);
            }
            break;
          }
          if (s > 0) q.consume(s); // 丢弃 preamble
          state = waitHeader;
          progressed = true;
          break;

        case waitHeader:
          final he = q.indexOf(headerEndMark, delimiter.length);
          if (he < 0) break; // 头还没收齐，等下一块（头部很小）
          final header =
              latin1.decode(q.slice(delimiter.length, he), allowInvalid: true);
          dataStart = he + 4;
          final lenMatch =
              RegExp(r'Content-Length\s*:\s*(\d+)', caseSensitive: false)
                  .firstMatch(header);
          if (lenMatch != null) {
            frameLen = int.tryParse(lenMatch.group(1)!) ?? 0;
            if (frameLen <= 0) {
              q.consume(dataStart);
              state = waitDelimiter;
            } else {
              state = waitFrame;
            }
          } else {
            state = waitNextBoundary;
            boundaryScan = dataStart;
          }
          progressed = true;
          break;

        case waitFrame:
          if (q.length < dataStart + frameLen) break;
          final frame = q.take(dataStart, dataStart + frameLen);
          q.consume(dataStart + frameLen);
          state = waitDelimiter;
          progressed = true;
          if (_isJpeg(frame)) yield frame;
          break;

        case waitNextBoundary:
          final next = q.indexOf(delimiter, boundaryScan);
          if (next < 0) {
            final candidate = q.length - delimiter.length + 1;
            if (candidate > boundaryScan) boundaryScan = candidate;
            break;
          }
          var end = next;
          while (end > dataStart && (q[end - 1] == 13 || q[end - 1] == 10)) {
            end--;
          }
          if (end > dataStart) {
            final frame = q.take(dataStart, end);
            if (_isJpeg(frame)) yield frame;
          }
          q.consume(next); // 保留 delimiter 供下一轮识别
          state = waitDelimiter;
          progressed = true;
          break;
      }
    }
    // 防御：异常流导致缓冲区无限膨胀。
    if (q.length > 8 * 1024 * 1024) {
      q.clear();
      state = waitDelimiter;
    }
  }
}

/// 无 multipart 封装时，按 JPEG SOI/EOI 标记切帧。
/// 用显式状态机区分「等待 SOI」与「等待 EOI」，保证 SOI/EOI 被网络拆到
/// 任意字节边界时都能正确组帧（单字节块也不会跳过已找到的 SOI）。
Stream<Uint8List> parseRawJpegFrames(Stream<List<int>> input) async* {
  const soi = <int>[0xFF, 0xD8];
  const eoi = <int>[0xFF, 0xD9];
  final q = _ByteQueue();
  var waitingEoi = false;
  var eoiScan = 2; // 等待 EOI 时的搜索起点，单调递增只扫新增区间

  await for (final chunk in input) {
    q.addAll(chunk);
    while (true) {
      if (!waitingEoi) {
        final s = q.indexOf(soi, 0);
        if (s < 0) {
          // 保留末尾 1 字节（可能是 SOI 的首字节 0xFF），丢弃其余噪声。
          if (q.length > 1) q.consume(q.length - 1);
          break;
        }
        if (s > 0) q.consume(s);
        waitingEoi = true;
        eoiScan = 2;
      }
      final e = q.indexOf(eoi, eoiScan);
      if (e < 0) {
        // 保留末尾 1 字节（可能是 EOI 的首字节 0xFF），下次从这里继续。
        final candidate = q.length - 1;
        if (candidate > eoiScan) eoiScan = candidate;
        break;
      }
      final frame = q.take(0, e + 2);
      q.consume(e + 2);
      waitingEoi = false;
      yield frame;
    }
    if (q.length > 8 * 1024 * 1024) {
      q.clear();
      waitingEoi = false;
      eoiScan = 2;
    }
  }
}

/// SS MJPEG 流客户端。以 stream 形式持续产出帧，调用方 cancel 即断开连接。
///
/// [maxFps] 上限帧率（默认 20）。网络帧快于 UI 解码时直接丢弃过期帧，
/// 只保留最新画面，避免解码队列堆积导致的延迟与卡顿；设为 <=0 表示不限流。
class MjpegStreamClient {
  MjpegStreamClient({required this.url, this.cookie = '', this.maxFps = 20});

  final String url;
  final String cookie;
  final int maxFps;

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
        final hint = await resp.transform(latin1.decoder).take(1).join();
        final cut = hint.length > 300 ? hint.substring(0, 300) : hint;
        // DSM 在 SID 过期时返回 HTTP 465 + 登录页 HTML：归类为会话失效，
        // 绝不把整段 HTML 甩到预览/回放界面上。
        final failure = classifyHttpResponse(resp.statusCode, cut);
        if (failure.needsReLogin) {
          throw MjpegException(failure.message, needsReLogin: true);
        }
        // 其它错误：去掉 HTML 标签，只保留简短可读的状态说明。
        final plain = cut
            .replaceAll(RegExp(r'<[^>]*>'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        final brief = plain.isEmpty
            ? ''
            : ' · ${plain.substring(0, plain.length > 60 ? 60 : plain.length)}';
        throw MjpegException('HTTP ${resp.statusCode}$brief');
      }
      final ct = resp.headers.value('content-type') ?? '';
      final boundary = boundaryFrom(ct);
      final Stream<Uint8List> source = boundary.isNotEmpty
          ? parseMjpegFrames(resp, boundary)
          : parseRawJpegFrames(resp);

      if (maxFps <= 0) {
        yield* source;
      } else {
        final minGapMicros = 1000000 ~/ maxFps;
        var lastYieldMicros = 0;
        await for (final frame in source) {
          final now = DateTime.now().microsecondsSinceEpoch;
          if (lastYieldMicros != 0 && now - lastYieldMicros < minGapMicros) {
            continue; // 丢掉过期帧，保持最新画面，不进解码队列
          }
          lastYieldMicros = now;
          yield frame;
        }
      }
    } finally {
      client.close(force: true);
    }
  }
}
