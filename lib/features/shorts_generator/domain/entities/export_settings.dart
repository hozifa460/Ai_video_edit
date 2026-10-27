import 'reframe_settings.dart';

enum PlatformTarget { tiktok, reels, shorts, instagramFeed, custom }

enum ClipDuration { s15, s30, s60, s90, m3, m5, m10, m15, custom }

enum CuttingMode { interval, smartAudio, scene, manual, ai }

enum ExportQuality { low, medium, high, veryHigh, ultra }

extension ExportQualityLabel on ExportQuality {
  String get label {
    switch (this) {
      case ExportQuality.low: return 'Low';
      case ExportQuality.medium: return 'Medium';
      case ExportQuality.high: return 'High';
      case ExportQuality.veryHigh: return 'Very High';
      case ExportQuality.ultra: return 'Ultra';
    }
  }

  String get description {
    switch (this) {
      case ExportQuality.low: return '~4 Mbps';
      case ExportQuality.medium: return '~8 Mbps';
      case ExportQuality.high: return '~12 Mbps';
      case ExportQuality.veryHigh: return '~20 Mbps';
      case ExportQuality.ultra: return '~30 Mbps';
    }
  }
}

class ExportSettings {
  final PlatformTarget platform;
  final ClipDuration maxDuration;
  final int clipCount;
  final int fps;
  final ExportQuality quality;
  final CuttingMode cuttingMode;
  final ReframeMode reframeMode;

  const ExportSettings({
    this.platform = PlatformTarget.tiktok,
    this.maxDuration = ClipDuration.s60,
    this.clipCount = 5,
    this.fps = 30,
    this.quality = ExportQuality.high,
    this.cuttingMode = CuttingMode.scene,
    this.reframeMode = ReframeMode.pillarbox,
  });

  int get bitrateMbps {
    switch (quality) {
      case ExportQuality.low: return 4;
      case ExportQuality.medium: return 8;
      case ExportQuality.high: return 12;
      case ExportQuality.veryHigh: return 20;
      case ExportQuality.ultra: return 30;
    }
  }

  int get targetWidth {
    switch (platform) {
      case PlatformTarget.tiktok:
      case PlatformTarget.reels:
      case PlatformTarget.shorts:
        return 1080;
      case PlatformTarget.instagramFeed:
        return 1080;
      case PlatformTarget.custom:
        return 1080;
    }
  }

  int get targetHeight {
    switch (platform) {
      case PlatformTarget.tiktok:
      case PlatformTarget.reels:
      case PlatformTarget.shorts:
        return 1920;
      case PlatformTarget.instagramFeed:
        return 1080;
      case PlatformTarget.custom:
        return 1920;
    }
  }

  double get maxDurationSeconds {
    switch (maxDuration) {
      case ClipDuration.s15:
        return 15;
      case ClipDuration.s30:
        return 30;
      case ClipDuration.s60:
        return 60;
      case ClipDuration.s90:
        return 90;
      case ClipDuration.m3:
        return 180;
      case ClipDuration.m5:
        return 300;
      case ClipDuration.m10:
        return 600;
      case ClipDuration.m15:
        return 900;
      case ClipDuration.custom:
        return 60;
    }
  }

  String get platformLabel {
    switch (platform) {
      case PlatformTarget.tiktok:
        return 'TikTok';
      case PlatformTarget.reels:
        return 'Reels';
      case PlatformTarget.shorts:
        return 'Shorts';
      case PlatformTarget.instagramFeed:
        return 'Instagram';
      case PlatformTarget.custom:
        return 'Custom';
    }
  }
}
