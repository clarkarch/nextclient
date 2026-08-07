import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';
import 'package:video_player/video_player.dart';

import '../../theme/neon.dart';
import '../neon_loading.dart';

/// Plays a single queue ad via [VideoPlayerController] (backed by the `fvp`
/// libmdk plugin on Windows/Linux/macOS, and the native plugin on Android/iOS).
///
/// Resolves the best media URL from a [SessionAdInfo] (preferred `mediaUrl`,
/// then `adUrl`, then the first `adMediaFiles` entry) and reports the ad's
/// lifecycle to the backend through [onReport]:
///  - `start` once playback begins,
///  - `finish` when the media completes (with the watched duration),
///  - `cancel` if the source fails to load.
///
/// If no usable media URL is present it renders the fallback text card instead
/// of playing anything.
class QueueAdPlayer extends StatefulWidget {
  final SessionAdInfo ad;
  final Future<void> Function(SessionAdAction action, {int? watchedMs})
      onReport;

  const QueueAdPlayer({super.key, required this.ad, required this.onReport});

  static String? resolveMediaUrl(SessionAdInfo ad) {
    final mediaUrl = ad.mediaUrl;
    if (mediaUrl != null && mediaUrl.isNotEmpty) return mediaUrl;
    final adUrl = ad.adUrl;
    if (adUrl != null && adUrl.isNotEmpty) return adUrl;
    for (final file in ad.adMediaFiles) {
      final f = file.mediaFileUrl;
      if (f != null && f.isNotEmpty) return f;
    }
    return null;
  }

  @override
  State<QueueAdPlayer> createState() => _QueueAdPlayerState();
}

class _QueueAdPlayerState extends State<QueueAdPlayer> {
  VideoPlayerController? _controller;
  bool _startedReported = false;
  bool _finishReported = false;
  bool _loadFailed = false;

  SessionAdInfo get ad => widget.ad;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final url = QueueAdPlayer.resolveMediaUrl(ad);
    if (url == null) {
      if (mounted) setState(() => _loadFailed = true);
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      if (mounted) setState(() => _loadFailed = true);
      return;
    }

    final controller = VideoPlayerController.networkUrl(uri);
    _controller = controller;
    controller.addListener(_onPlayerUpdate);
    try {
      await controller.initialize();
      if (!mounted) return;
      setState(() {});
      await controller.setLooping(false);
      await controller.play();
    } catch (e) {
      debugPrint('[queue-ad] load failed: $e');
      await _report(SessionAdAction.cancel);
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Future<void> _report(SessionAdAction action, {int? watchedMs}) async {
    try {
      await widget.onReport(action, watchedMs: watchedMs);
    } catch (e) {
      debugPrint('[queue-ad] report $action failed: $e');
    }
  }

  void _onPlayerUpdate() {
    final value = _controller?.value;
    if (value == null) return;

    if (value.isInitialized && !_startedReported && value.isPlaying) {
      _startedReported = true;
      unawaited(_report(SessionAdAction.start));
    }

    if (!_finishReported && value.isCompleted) {
      _finishReported = true;
      final watched = value.position.inMilliseconds;
      unawaited(_report(SessionAdAction.finish, watchedMs: watched));
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      controller.removeListener(_onPlayerUpdate);
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loadFailed || _controller == null) {
      return _fallbackCard(context);
    }
    final value = _controller!.value;
    if (!value.isInitialized) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: NeonSpinner(size: 26)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: value.aspectRatio > 0 ? value.aspectRatio : 16 / 9,
        child: VideoPlayer(_controller!),
      ),
    );
  }

  Widget _fallbackCard(BuildContext context) {
    final title = ad.title?.isNotEmpty == true ? ad.title! : ad.adId;
    final description = ad.description?.isNotEmpty == true
        ? ad.description!
        : 'Advertisement — finish watching to continue queueing.';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x0FFFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Neon.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: Neon.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(description,
              style: const TextStyle(color: Neon.inkMuted, fontSize: 12)),
        ],
      ),
    );
  }
}
