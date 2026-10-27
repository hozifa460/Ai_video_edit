import 'package:equatable/equatable.dart';
import '../../../../core/enums/export_quality.dart';

class ExportParams extends Equatable {
  final String outputPath;
  final String fileName;
  final String format;
  final ExportQuality quality;

  const ExportParams({
    required this.outputPath,
    required this.fileName,
    required this.format,
    required this.quality,
  });

  @override
  List<Object?> get props => [outputPath, fileName, format, quality];
}
