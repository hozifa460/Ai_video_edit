import 'package:equatable/equatable.dart';
import '../../../../core/constants/app_constants.dart';

class SmartZoomConfig {
  final bool enabled;
  final double zoomAmount;

  const SmartZoomConfig({this.enabled = false, this.zoomAmount = 1.05})
    : assert(zoomAmount >= 1.0);

  SmartZoomConfig copyWith({bool? enabled, double? zoomAmount}) {
    return SmartZoomConfig(
      enabled: enabled ?? this.enabled,
      zoomAmount: zoomAmount ?? this.zoomAmount,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SmartZoomConfig &&
          enabled == other.enabled &&
          zoomAmount == other.zoomAmount;

  @override
  int get hashCode => Object.hash(enabled, zoomAmount);
}

class DetectionParams extends Equatable {
  final double silenceThreshold;
  final double minSilenceDuration;
  final double paddingBefore;
  final double paddingAfter;
  final bool useVad;
  final bool useBreathingProtection;
  final SmartZoomConfig smartZoom;

  const DetectionParams({
    required this.silenceThreshold,
    required this.minSilenceDuration,
    required this.paddingBefore,
    required this.paddingAfter,
    this.useVad = true,
    this.useBreathingProtection = true,
    this.smartZoom = const SmartZoomConfig(),
  });

  const DetectionParams.defaults()
    : silenceThreshold = AppConstants.defaultSilenceThreshold,
      minSilenceDuration = 0.25,
      paddingBefore = 0.08,
      paddingAfter = 0.08,
      useVad = true,
      useBreathingProtection = true,
      smartZoom = const SmartZoomConfig();

  DetectionParams copyWith({
    double? silenceThreshold,
    double? minSilenceDuration,
    double? paddingBefore,
    double? paddingAfter,
    bool? useVad,
    bool? useBreathingProtection,
    SmartZoomConfig? smartZoom,
  }) {
    return DetectionParams(
      silenceThreshold: silenceThreshold ?? this.silenceThreshold,
      minSilenceDuration: minSilenceDuration ?? this.minSilenceDuration,
      paddingBefore: paddingBefore ?? this.paddingBefore,
      paddingAfter: paddingAfter ?? this.paddingAfter,
      useVad: useVad ?? this.useVad,
      useBreathingProtection:
          useBreathingProtection ?? this.useBreathingProtection,
      smartZoom: smartZoom ?? this.smartZoom,
    );
  }

  String get ffmpegNoiseLevel => silenceThreshold.toStringAsFixed(1);

  @override
  List<Object?> get props => [
    silenceThreshold,
    minSilenceDuration,
    paddingBefore,
    paddingAfter,
    useVad,
    useBreathingProtection,
    smartZoom,
  ];
}
