import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/utils/result.dart';
import '../entities/video_file.dart';
import '../repositories/video_import_repository.dart';
import '../../data/repositories/video_import_repository_impl.dart';

final videoImportRepositoryProvider = Provider<VideoImportRepository>(
  (ref) => VideoImportRepositoryImpl(),
);

final videoImportProvider = FutureProvider.autoDispose
    .family<VideoFile, String>((ref, path) async {
  final repository = ref.read(videoImportRepositoryProvider);
  final result = await repository.getVideoMetadata(path);
  if (result is Success<VideoFile>) return result.value;
  throw (result as AppError).error;
});
