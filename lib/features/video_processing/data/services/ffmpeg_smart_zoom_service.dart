import '../../../silence_detector/domain/entities/detection_params.dart';
import '../../../../core/utils/logger.dart';

class FfmpegSmartZoomService {
  String? buildZoomFilter(int segmentIndex, SmartZoomConfig config) {
    if (!config.enabled || config.zoomAmount <= 1.0) return null;

    final shouldZoom = segmentIndex % 2 == 0;
    if (!shouldZoom) return null;

    final z = config.zoomAmount.toStringAsFixed(3);
    final filter = 'scale=iw*$z:ih*$z:flags=bilinear,crop=iw/$z:ih/$z,setsar=1';

    AppLogger().i(
      'SmartZoom: segment $segmentIndex zoom=${config.zoomAmount}x',
    );
    return filter;
  }
}
