// 实时声音开关。
//
// 官方 KB：MJPEG 录像/实时皆不支持音频；MPEG4/H.264/H.265 的「视频流」
// 同样不含音轨，声音由群晖独立的 AudioStream 流提供（audioStreaming.cgi）。
// 因此实时声音不能靠换视频格式解决，必须单独播放这条音频流。
//
// 复用 video_player 的 AVPlayer/ExoPlayer 播放纯音频流，不引入新依赖。
// 摄像机本身未配音频、或 NAS 未提供该 CGI 时，会给出真实失败提示而非静默。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../data/models/camera.dart';
import '../state/app_state.dart';

class LiveAudioButton extends StatefulWidget {
  const LiveAudioButton({super.key, required this.camera});

  final Camera camera;

  @override
  State<LiveAudioButton> createState() => _LiveAudioButtonState();
}

class _LiveAudioButtonState extends State<LiveAudioButton> {
  VideoPlayerController? _controller;
  bool _on = false;
  bool _busy = false;

  Future<void> _toggle() async {
    if (_busy) return;
    if (_on) {
      await _stop();
      return;
    }
    // 在任何 await 之前取出 messenger，避免 async gap 后使用 context。
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    VideoPlayerController? c;
    try {
      final state = context.read<AppState>();
      final url = state.audioStreamUrl(widget.camera);
      c = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: <String, String>{
          if (state.cookieHeader.isNotEmpty) 'Cookie': state.cookieHeader,
        },
      );
      await c.initialize();
      await c.setVolume(1.0);
      await c.play();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _on = true;
      });
    } catch (e) {
      try {
        if (c != null) await c.dispose();
      } catch (_) {
        // 清理失败不影响提示。
      }
      if (mounted) {
        messenger.showSnackBar(SnackBar(
          content: Text('实时声音开启失败：$e\n'
              '请确认摄像机启用了音频（G.711/G.726/PCM/AAC），'
              '且视频格式不是 MJPEG。'),
          duration: const Duration(seconds: 5),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    final c = _controller;
    _controller = null;
    if (mounted) setState(() => _on = false);
    if (c != null) await c.dispose();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: _on ? '关闭实时声音' : '开启实时声音（需摄像机支持音频）',
      child: GestureDetector(
        onTap: _toggle,
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: _on ? Colors.green.shade700 : Colors.black38,
            borderRadius: BorderRadius.circular(6),
          ),
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Icon(_on ? Icons.volume_up : Icons.volume_off,
                  size: 18, color: Colors.white),
        ),
      ),
    );
  }
}
