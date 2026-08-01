class IceCandidatePayload {
  final String candidate;
  final String? sdpMid;
  final int sdpMLineIndex;
  final String? usernameFragment;

  const IceCandidatePayload({
    required this.candidate,
    this.sdpMid,
    required this.sdpMLineIndex,
    this.usernameFragment,
  });
}

class SendAnswerRequest {
  final String sdp;
  final String? nvstSdp;

  const SendAnswerRequest({required this.sdp, this.nvstSdp});
}

class KeyframeRequest {
  final String reason;
  final int backlogFrames;
  final int attempt;

  const KeyframeRequest({
    required this.reason,
    required this.backlogFrames,
    required this.attempt,
  });
}

enum MainToRendererSignalingEventType {
  connected,
  disconnected,
  offer,
  remoteIce,
  error,
  log,
}

class MainToRendererSignalingEvent {
  final MainToRendererSignalingEventType type;
  final String? message;
  final String? reason;
  final String? sdp;
  final IceCandidatePayload? candidate;

  const MainToRendererSignalingEvent({
    required this.type,
    this.message,
    this.reason,
    this.sdp,
    this.candidate,
  });
}