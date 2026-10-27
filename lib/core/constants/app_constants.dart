class AppConstants {
  AppConstants._();

  static const String appName = 'Silence Remover';
  static const String appVersion = '1.0.0';

  static const List<String> supportedVideoExtensions = [
    '.mp4', '.mov', '.mkv', '.avi', '.webm',
  ];

  static const List<String> supportedVideoFormats = [
    'mp4', 'mov', 'mkv', 'avi', 'webm',
  ];

  static const double defaultSilenceThreshold = -30.0;
  static const double minSilenceThreshold = -110.0;
  static const double maxSilenceThreshold = -10.0;

  static const double defaultMinSilenceDuration = 0.25;
  static const double minSilenceDuration = 0.01;
  static const double maxSilenceDuration = 5.0;

  static const double defaultPadding = 0.15;
  static const double minPadding = 0.0;
  static const double maxPadding = 0.5;

  static const int audioSampleRate = 16000;
  static const int audioChannels = 1;

  static const String tempAudioFileName = 'extracted_audio.wav';
  static const String tempOutputFileName = 'processed_output.mp4';

  static const Duration splashDuration = Duration(seconds: 2);
}
