enum ReframeMode { centerCrop, pillarbox, faceAware, blurBackground, cinematicLetterbox, kenBurns, shadowGlow, mirrorSplit }

extension ReframeModeLabel on ReframeMode {
  String get label {
    switch (this) {
      case ReframeMode.centerCrop:
        return 'Full Screen';
      case ReframeMode.pillarbox:
        return 'Pillarbox';
      case ReframeMode.faceAware:
        return 'Face Track';
      case ReframeMode.blurBackground:
        return 'Blur BG';
      case ReframeMode.cinematicLetterbox:
        return 'Cinematic';
      case ReframeMode.kenBurns:
        return 'Ken Burns';
      case ReframeMode.shadowGlow:
        return 'Glow BG';
      case ReframeMode.mirrorSplit:
        return 'Mirror';
    }
  }

  String get description {
    switch (this) {
      case ReframeMode.centerCrop:
        return 'Crop to fill 9:16';
      case ReframeMode.pillarbox:
        return 'Fit in frame + black bars';
      case ReframeMode.faceAware:
        return 'Smart face tracking';
      case ReframeMode.blurBackground:
        return 'Blurred background';
      case ReframeMode.cinematicLetterbox:
        return '2.35:1 cinematic bars';
      case ReframeMode.kenBurns:
        return 'Slow zoom animation';
      case ReframeMode.shadowGlow:
        return 'Glow behind video';
      case ReframeMode.mirrorSplit:
        return 'Mirror preview effect';
    }
  }
}

class ReframeSettings {
  final ReframeMode mode;
  final int targetWidth;
  final int targetHeight;

  const ReframeSettings({
    this.mode = ReframeMode.pillarbox,
    this.targetWidth = 1080,
    this.targetHeight = 1920,
  });

  ReframeSettings copyWith({ReframeMode? mode, int? targetWidth, int? targetHeight}) {
    return ReframeSettings(
      mode: mode ?? this.mode,
      targetWidth: targetWidth ?? this.targetWidth,
      targetHeight: targetHeight ?? this.targetHeight,
    );
  }
}
