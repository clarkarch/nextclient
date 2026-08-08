import 'package:flutter/material.dart';
import 'package:gfn_core/gfn_core.dart';

import '../../theme/neon.dart';
import '../../widgets/neon_button.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/stream/queue_ad_player.dart';

/// Debug tool for exercising the queue-ad playback path (fvp / video_player)
/// with an arbitrary media URL, without queueing for or starting a real
/// session. Reuses [QueueAdPlayer] exactly as the live queue does.
class AdsTesterPage extends StatefulWidget {
  const AdsTesterPage({super.key});

  @override
  State<AdsTesterPage> createState() => _AdsTesterPageState();
}

class _AdsTesterPageState extends State<AdsTesterPage> {
  static const _defaultUrl =
      'https://commondatastorage.googleapis.com/'
      'gtv-videos-bucket/sample/BigBuckBunny.mp4';

  late final TextEditingController _url = TextEditingController(
    text: _defaultUrl,
  );
  String? _activeUrl;

  void _play() {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    setState(() => _activeUrl = url);
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NeonPageScaffold(
      title: 'Ads tester',
      showBack: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Play an ad/creative media URL using the same fvp-backed '
            'VideoPlayerController path the queue uses. Playback reports '
            '(start / finish / cancel) are swallowed here.',
            style: TextStyle(color: Neon.inkMuted, fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          NeonCard(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _url,
                    onSubmitted: (_) => _play(),
                    style: const TextStyle(color: Neon.ink, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Paste ad media URL (mp4 / hls)…',
                      hintStyle: const TextStyle(
                        color: Neon.inkMuted,
                        fontSize: 12.5,
                      ),
                      filled: true,
                      fillColor: Neon.bgB,
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: Neon.outline),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: Neon.outline),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                NeonButton(
                  label: 'Play',
                  icon: Icons.play_arrow,
                  onPressed: _play,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_activeUrl != null)
            QueueAdPlayer(
              key: ValueKey(_activeUrl),
              ad: SessionAdInfo(
                adId: 'ads-tester',
                mediaUrl: _activeUrl,
                title: 'Ads tester',
                description: 'Debug playback via fvp — not a real ad.',
              ),
              onReport: (action, {watchedMs}) async {
                debugPrint(
                  '[ads-tester] action=$action'
                  '${watchedMs != null ? ' watched=$watchedMs ms' : ''}',
                );
              },
            ),
        ],
      ),
    );
  }
}
