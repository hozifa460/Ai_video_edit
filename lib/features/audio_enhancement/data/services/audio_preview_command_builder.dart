class AudioPreviewCommandBuilder {
  const AudioPreviewCommandBuilder._();

  static String buildOriginalPreviewCommand({
    required String inputPath,
    required String outputPath,
    double seconds = 12,
  }) {
    return '-ss 0.000 -t ${_fmt(seconds)} -i "${_normalizePath(inputPath)}" '
        '-map 0:a:0 -vn -ac 2 -ar 48000 '
        '-c:a aac -b:a 256k -movflags +faststart '
        '-y "${_normalizePath(outputPath)}"';
  }

  static String buildEnhancedPreviewCommand({
    required String inputPath,
    required String outputPath,
    required String audioFilter,
    double seconds = 12,
  }) {
    final afPart = audioFilter.isNotEmpty ? '-af "$audioFilter" ' : '';
    return '-ss 0.000 -t ${_fmt(seconds)} -i "${_normalizePath(inputPath)}" '
        '-map 0:a:0 -vn -ac 2 -ar 48000 '
        '$afPart'
        '-c:a aac -b:a 256k -movflags +faststart '
        '-y "${_normalizePath(outputPath)}"';
  }

  static String _normalizePath(String path) => path.replaceAll('\\', '/');

  static String _fmt(double seconds) => seconds.toStringAsFixed(3);
}
