import 'package:flutter/material.dart';

import '../../main.dart';
import '../../state/stream_transport.dart';
import '../../state/user_settings.dart';
import '../../theme/neon.dart';
import '../../widgets/neon_card.dart';
import '../../widgets/neon_option_chip.dart';
import '../../widgets/neon_page_scaffold.dart';
import '../../widgets/neon_switch.dart';

/// Experimental settings: unverified options that tweak how the NVIDIA server
/// adapts the stream. They are baked into the nvstSdp at session start, so they
/// only affect new sessions, and the server may ignore them.
class ExperimentalSettingsPage extends StatelessWidget {
  final AppServices services;

  const ExperimentalSettingsPage({super.key, required this.services});

  @override
  Widget build(BuildContext context) {
    return NeonPageScaffold(
      title: 'Experimental',
      showBack: true,
      child: ListenableBuilder(
        listenable: services.settings,
        builder: (context, _) {
          final s = services.settings;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NeonCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'TRANSPORT',
                      style: TextStyle(
                        color: Neon.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Which WebRTC engine carries the stream. GStreamer webrtcbin '
                      'uses hardware decode (VAAPI/FFmpeg) via the native bridge '
                      '(build with `make -C native/gst_bridge`) — no custom '
                      'libwebrtc build needed. Applies to the next session.',
                      style: const TextStyle(
                        color: Neon.inkMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final t in StreamTransportKind.values)
                          NeonOptionChip(
                            label: switch (t) {
                              StreamTransportKind.flutterWebrtc =>
                                'LIBWEBRTC (default)',
                              StreamTransportKind.webrtcbinFfi =>
                                'WEBRTCBIN (FFI)',
                              StreamTransportKind.nvstGstreamer =>
                                'NVST (GStreamer)',
                            },
                            selected: t == s.streamTransport,
                            onTap: () => s.streamTransport = t,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              NeonCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'LIBWEBRTC DECODER',
                      style: TextStyle(
                        color: Neon.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Which decode backend the custom libwebrtc uses. '
                      'VAAPI (GStreamer) hardware-decodes H.264 first and falls '
                      'back to FFmpeg; FFmpeg forces software decode. Applies '
                      'to the next session. Stats overlay Decoder row reads '
                      'GStreamerVaapiH264 vs FFmpegVideoDecoder.',
                      style: TextStyle(
                        color: Neon.inkMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final b in DecoderBackend.values)
                          NeonOptionChip(
                            label: switch (b) {
                              DecoderBackend.vaapi => 'VAAPI (GStreamer)',
                              DecoderBackend.ffmpeg => 'FFMPEG (software)',
                            },
                            selected: b == s.decoderBackend,
                            onTap: () => s.decoderBackend = b,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              NeonCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'RENDERER',
                      style: TextStyle(
                        color: Neon.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'How the Linux libwebrtc path delivers decoded frames to '
                      'Flutter. CPU (default) is the stock libyuv '
                      'ConvertToARGB into a pixel buffer. GL uploads the Y/U/V '
                      'planes as textures and runs the YUV→RGB chroma '
                      'upsampling in a fragment shader (OpenNOW-style) — the '
                      'engine composites the GPU texture with no CPU readback. '
                      'Applies to the next session; used for A/B.',
                      style: const TextStyle(
                        color: Neon.inkMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final r in RendererBackend.values)
                          NeonOptionChip(
                            label: switch (r) {
                              RendererBackend.cpu => 'CPU (ARGB convert)',
                              RendererBackend.gl => 'GL (shader YUV→RGB)',
                            },
                            selected: r == s.rendererBackend,
                            onTap: () => s.rendererBackend = r,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              NeonCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'STREAM PRIORITY PRESETS',
                            style: TextStyle(
                              color: Neon.accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2,
                            ),
                          ),
                        ),
                        NeonSwitch(
                          value: s.streamPriorityEnabled,
                          onChanged: (v) => s.streamPriorityEnabled = v,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      s.streamPriorityEnabled
                          ? 'Active — server adaptation presets below are sent via '
                                'nvstSdp. OFF is the safe default (matches the '
                                'original OpenNOW profile).'
                          : 'Off (default) — the stream always uses the safe '
                                'quality profile, matching the original OpenNOW '
                                'behavior. Enable to experiment.',
                      style: const TextStyle(
                        color: Neon.inkMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final p in StreamPriority.values)
                          NeonOptionChip(
                            label: p.name.toUpperCase(),
                            selected: p == s.streamPriority,
                            enabled: s.streamPriorityEnabled,
                            onTap: () => s.streamPriority = p,
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      s.streamPriorityEnabled
                          ? switch (s.streamPriority) {
                              StreamPriority.quality =>
                                'Full resolution & bitrate; drops decode FPS under '
                                    'load.',
                              StreamPriority.balanced =>
                                'Balances resolution and FPS (allows downscaling).',
                              StreamPriority.fps =>
                                'Holds frame rate; scales resolution down first.',
                            }
                          : 'Presets disabled — quality profile in effect.',
                      style: const TextStyle(
                        color: Neon.inkSoft,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              NeonCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'LATENCY',
                      style: TextStyle(
                        color: Neon.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Low-latency mode',
                            style: TextStyle(
                              color: Neon.ink,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        NeonSwitch(
                          value: s.optLowLatencyMode,
                          onChanged: (v) => s.optLowLatencyMode = v,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Tightens server frame pacing, packet delay budget and '
                      'RTCP feedback cadence so less video is buffered ahead of '
                      'the display. Lower input latency, less jitter tolerance. '
                      'Applies to new sessions.',
                      style: const TextStyle(
                        color: Neon.inkMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'RECOVERY',
                      style: TextStyle(
                        color: Neon.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'How the server repairs packet loss. Smooth keeps a deep '
                      'NACK window (resilient, but grows latency under loss); '
                      'latency uses a shallow window + fresh keyframes (lowest '
                      'latency, more artifacts).',
                      style: const TextStyle(
                        color: Neon.inkMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final p in StreamRecoveryProfile.values)
                          NeonOptionChip(
                            label: p.name.toUpperCase(),
                            selected: p == s.optRecoveryProfile,
                            onTap: () => s.optRecoveryProfile = p,
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'MIN BITRATE FLOOR',
                      style: TextStyle(
                        color: Neon.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Lower bound the server targets even when bandwidth '
                      'estimation drops. Higher = stable quality; lower = faster '
                      'BWE shed on a bad link.',
                      style: const TextStyle(
                        color: Neon.inkMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Slider(
                            value: (s.optMinBitrateKbps / 1000).clamp(1, 30),
                            min: 1,
                            max: 30,
                            divisions: 29,
                            activeColor: Neon.accent,
                            inactiveColor: Neon.bgC,
                            label: '${s.optMinBitrateKbps ~/ 1000} Mbps',
                            onChanged: (v) =>
                                s.optMinBitrateKbps = (v * 1000).round(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${s.optMinBitrateKbps ~/ 1000} Mbps',
                          style: const TextStyle(
                            color: Neon.inkSoft,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Enable NACK retransmission',
                            style: TextStyle(
                              color: Neon.ink,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        NeonSwitch(
                          value: s.optEnableNack,
                          onChanged: (v) => s.optEnableNack = v,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Enable FEC forward error correction',
                            style: TextStyle(
                              color: Neon.ink,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        NeonSwitch(
                          value: s.optEnableFec,
                          onChanged: (v) => s.optEnableFec = v,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Both negotiate recovery with the server. Disabling both '
                      'maximizes bandwidth headroom for video but makes loss '
                      'bursts more visible.',
                      style: const TextStyle(
                        color: Neon.inkMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
