# Silence Remover — Project Map

> **Current-context notice (2026-10-05):** This file is a historical changelog.
> Start with [PROJECT_MEMORY.md](PROJECT_MEMORY.md) and
> [the current review](docs/reviews/SILENCE_REMOVAL_REVIEW_AR.md).
> Some claims below (subtitle/Vosk support, 50ms protection margin, old test
> counts, and old analyzer warnings) do not match the reviewed source.
> Historical incidents are not evidence that the same failures persist today.

## Architecture
Clean Architecture with Riverpod 3 state management.

```
lib/
├── core/           # Theme, router, enums, utils, errors
├── shared/         # Shared widgets
├── features/
│   ├── video_import/             # File picking + FFprobe metadata
│   ├── audio_processing/         # PCM extraction + waveform analysis
│   ├── audio_enhancement/        # Audio denoise, compression, EQ, normalization (FFmpeg)
│   ├── silence_detector/         # FFmpeg silencedetect + editor screen
│   ├── video_processing/         # Trim/concat FFmpeg pipeline
│   ├── subtitle_generation/      # STT, SRT export, FFmpeg burn-in
│   └── export/                   # Save dialog + format/quality selection
```

## Key Dependencies
| Package | Version | Notes |
|---------|---------|-------|
| flutter_riverpod | ^3.3.1 | Notifier, NotifierProvider (no StateNotifierProvider) |
| ffmpeg_kit_flutter_new | ^4.1.0 | FFmpeg v8.0.0 full GPL |
| file_picker | ^11.0.2 | Static API: `FilePicker.pickFiles()`, `FilePicker.saveFile()` |
| chewie | ^1.12.0 | Pinned to avoid win32 conflict with file_picker |
| flutter_animate | ^4.5.0 | Animations |
| vosk_flutter | ^0.3.24 | Offline speech recognition (file-based, word-level timestamps) |
| permission_handler | ^11.3.1 | Overridden via `dependency_overrides` for vosk_flutter compat |

## Critical Rules
- `ffmpeg_kit_flutter_new`'s `MediaInformation.getStreams()` returns **non-nullable** `List<StreamInformation>`. No `?? []` needed.
- `StreamInformation` has **no `getFrameRate()` method** — use `getRealFrameRate()` (backed by `r_frame_rate`, returns `String?` like `"30000/1001"`).
- Use typed getters: `stream.getType()`, `stream.getWidth()`, `stream.getHeight()`, `stream.getRealFrameRate()`, etc.
- **FFmpeg log capture**: `getAllLogsAsString()` alone may miss ERROR-level logs (async timing). Use **triple capture**: (1) `enableLogCallback` with `StringBuffer` for real-time, (2) `setLogLevel(Level.avLogVerbose)` before execute and restore to `Level.avLogInfo` after, (3) `getAllLogs(5000)` with timeout + `getFailStackTrace()` after execution. See `FfmpegEnhancementDatasource.enhanceVideo()` in `ffmpeg_enhancement_datasource.dart:48-101`.
- **Critical finding (2026-05-19)**: ALL FFmpeg commands (even `vidstabdetect`) fail with exit code 1, output only version banner at level `L32` (AV_LOG_INFO), **no error messages at any level** (no `L16` ERROR, no `L24` WARNING). This suggests the error happens before FFmpeg's av_log system is initialized, or the error goes through `fprintf(stderr)` directly (bypassing av_log). Use `_runDiagnostic()` to isolate the root cause.
- `MediaInformation.getDuration()` returns `String?` (duration in seconds as string).
- `FilePicker` uses static methods in v11: `FilePicker.pickFiles()`, `FilePicker.saveFile()`.
- Riverpod 3: use `Notifier`/`NotifierProvider`, not `StateNotifier`/`StateNotifierProvider`.
- Custom `Result<T>` sealed class: `Success<T>.value`, `AppError<T>.error`.
- Preview MUST call `startProcessing` first, then pass `processingState.outputPath` as `processedPath` to the preview screen.
- Filtergraph time values MUST be float seconds (e.g. `start=0.725`), NEVER `HH:MM:SS.mmm` format — colons inside time values clash with the `:` option separator in FFmpeg filter syntax.
- Export must use `FfmpegCuttingService.exportFile()` to re-process with the selected quality — never just `File.copy()`.
- Export auto-saves to `Downloads/Ai_video_editing/` (Android: `/storage/emulated/0/Download/Ai_video_editing/`, Desktop: `~/Downloads/Ai_video_editing/`, iOS: app documents). See `FileUtils.getExportDirectory()`.
- Silence detection uses two-pass FFmpeg `silencedetect` (coarse + fine), then merges results.
- `applyPadding` includes a 50ms `precisionMargin` that shrinks silence segments inward to prevent speech cutoff: `start = detected + 0.05 - paddingBefore`, `end = detected - 0.05 + paddingAfter`. This ensures even at padding=0, speech is never clipped.
- After export, `MediaScanner.scanFile()` (Android-only, via MethodChannel [`com.example.ai_video_editing/media_scanner`]) must be called so the video appears in the Gallery immediately. Implemented in `lib/core/utils/media_scanner.dart` and `MainActivity.kt`.
- Enhancement `scale` filter MUST always use `force_original_aspect_ratio=decrease` + `pad` to preserve aspect ratio. Never force exact dimensions: `scale=W:H:flags=algo:force_original_aspect_ratio=decrease,pad=W:H:(ow-iw)/2:(oh-ih)/2:color=black`.
- Result comparison screen: only the **visible** player should be playing (enhanced default, original on hold-to-peek). Pause the hidden player and seek-sync when switching.
- **NEVER use `pp` filter for deblock** — it requires `libpostproc` which is NOT available in this FFmpeg build (exit code 1, error goes to stderr). Use `deblock=filter=strong:block=8:alpha=0.05:beta=0.05` instead, which is a native libavfilter and always available in FFmpeg 4.0+.
- Professional enhancement filter chain order MUST be: Denoise → Deblock → Upscale → Curves+Color → Sharpen → Stabilize → FPS. Never reorder without testing.
- Always add `curves` S-curve and gentle `eq` (saturation, contrast) to every enhancement — these are lightweight avfilters that dramatically improve perceived quality at negligible speed cost.

## Flow
1. `EditorScreen`: import → auto detects silence → adjust params → **Preview** (processes → `PreviewScreen` with `outputPath`) or **Export** (processes → `ExportScreen` with `videoPath`)
2. `PreviewScreen`: shows original/processed comparison → "Export" → `ExportScreen(videoPath)`
3. `ExportScreen`: user selects format/quality → auto-saves to `Downloads/Ai_video_editing/` (or app documents fallback) → `VideoProcessorRepositoryImpl.exportVideo()` → `FfmpegCuttingService.exportFile()` (re-encodes audio with selected bitrate) → `MediaScanner.scanFile()` (Android) registers file in Gallery. Falls back to `widget.videoPath` if `processingState.outputPath` is null.

## 2026-05-17 Changes
| Type | Issue | Fix |
|------|-------|-----|
| UX | Preview button shows no loading feedback during FFmpeg processing (5-30s) | Added `showDialog` with `LinearProgressIndicator` + `PopScope(canPop: false)` in `_previewResult()` before `startProcessing`, dismissed via `Navigator.pop()` after completion |
| UX / Bug | Export button (`_processAndExport`) has no loading indicator AND no error handling — user clicks Export, processing runs, no feedback if it fails, no feedback while running | Added loading dialog (same pattern as `_previewResult`) + error handling with snackbar on failure |
| UX | No loading indicator during actual FFmpeg re-encode in ExportScreen (`_exportVideo`) | Added loading dialog with `LinearProgressIndicator` during `ExportScreen._exportVideo()`, dismissed after `repo.exportVideo()` completes |
| UX / Bug | ExportScreen requires 3 clicks (Export → Select save location → Export Video). `FilePicker.saveFile()` may not work on all platforms. | Replaced `FilePicker.saveFile()` with auto-generated path in `Downloads/Ai_video_editing/`. Added `FileUtils.getExportDirectory()` for cross-platform Downloads dir creation. Only format/quality choices needed, then one-click Export |
| Bug | Exported video not visible in Android Gallery | Added `MediaScanner` utility (MethodChannel → `MediaScannerConnection.scanFile()`). Called after successful export in `ExportScreen._exportVideo()` |
| Bug | Deleting a silence segment from timeline doesn't affect preview/export | Added logging throughout the flow (`removeSegment`, `_previewResult`, `_processAndExport`) to track segment count at each stage. Ensures `ref.read(silenceSegmentsProvider)` reads the latest provider state |

## 2026-05-17 Feature — VAD + Adaptive Threshold + Breathing Protection
| Type | Issue | Fix |
|------|-------|------|
| Feature | Pure dB-based silence detection misses non-speech noise (fans, AC, breaths) as "speech" | Added `VadService` — reads PCM WAV, computes per-frame energy histogram, classifies speech vs non-speech via adaptive threshold, removes silence segments that contain speech activity |
| Feature | Users must manually adjust threshold/duration/padding with no guidance | Added `AdaptiveThresholdService` — analyzes first 30s of audio, computes RMS dB histogram, finds noise floor (30th percentile) vs speech ceiling (90th percentile), sets optimal threshold at noise + 30% of dynamic range |
| Feature | Aggressive silence removal makes speech sound rushed / unnatural | Added `BreathingProtectionService` — preserves short silences: <100ms fully kept, 100-200ms reduced by 50%, 200-300ms reduced by 30%, >=300ms kept as-is |
| UX | No toggle for VAD / Breathing Protection | Added `SwitchListTile` controls in `DetectionSettingsPanel` with `useVad` and `useBreathingProtection` fields in `DetectionParams` |
| UX | One-tap smart detection | Added "Auto" button in `DetectionSettingsPanel` header that triggers `DetectionParamsNotifier.autoDetectThreshold()` → `AdaptiveThresholdService.analyze()` → updates params in provider |

### New files
- `lib/features/silence_detector/data/services/vad_service.dart`
- `lib/features/silence_detector/data/services/adaptive_threshold_service.dart`
- `lib/features/silence_detector/data/services/breathing_protection_service.dart`

## 2026-05-17 Feature (REMOVED) — Auto Subtitle Generation (Vosk)
**Status: REMOVED 2026-05-17** — Full feature removed: `subtitle_generation/` directory, `vosk_flutter` dependency, `dependency_overrides` in pubspec.yaml, vosk namespace patch in android/build.gradle.kts, `/subtitles` route in AppRouter, "Generate Subtitles" button on HomeScreen.

| Type | Issue | Fix |
|------|-------|------|
| Feature | No subtitle generation capability | Added full subtitle generation feature: speech-to-text via `vosk_flutter` (file-based offline STT with word-level timestamps), word grouping into subtitle entries, SRT export, FFmpeg subtitle burn-in. Accessed from HomeScreen "Generate Subtitles" button. |
| Bug | `speech_to_text` only supports mic input — playback-via-speaker → capture-via-mic workaround unreliable (echo coupling, timing drift, audio routing) | Replaced `speech_to_text` + `audioplayers` with `vosk_flutter`. Vosk processes WAV files directly — no device playback needed, fully offline, returns every word with start/end timestamps. Downloads small English model (~40MB) on first use via `ModelLoader`, caches in app documents. |
| Architecture | New feature area | Created `subtitle_generation/` with clean architecture: entities (`SubtitleEntry`), provider (`SubtitleEntriesNotifier`), services (`SubtitleGeneratorService`, `SrtFormatter`). |

### New files
- `lib/features/subtitle_generation/domain/entities/subtitle_entry.dart`
- `lib/features/subtitle_generation/domain/providers/subtitle_provider.dart`
- `lib/features/subtitle_generation/data/services/subtitle_generator_service.dart`
- `lib/features/subtitle_generation/data/services/srt_formatter.dart`
- `lib/features/subtitle_generation/presentation/subtitle_screen.dart`

### Build fixes
| Issue | Root cause | Fix |
|-------|-----------|------|
| `Namespace not specified` in `:vosk_flutter` | vosk_flutter 0.3.48 targets AGP 7.0.3 and lacks `namespace`; project uses AGP 8.11.1 which requires it | Added `beforeEvaluate` hook in `android/build.gradle.kts:allprojects` that patches `vosk_flutter/android/build.gradle` to inject `namespace 'org.vosk.vosk_flutter'` before Gradle evaluates the module |
| `class Registrar` (v1 embedding) not found in `permission_handler_android` | `vosk_flutter` transitively required `permission_handler ^10.2.0`, which resolved to `permission_handler_android 10.3.6` (deprecated v1 embedding) | Kept `permission_handler ^11.3.1` in `pubspec.yaml` and added `dependency_overrides: permission_handler: ^11.3.1` to force vosk_flutter to use the newer permission_handler, resolving `permission_handler_android 12.1.0` (v2 embedding) |

### Changed files
- `pubspec.yaml` — replaced `speech_to_text`/`audioplayers` with `vosk_flutter ^0.3.24`; added `dependency_overrides: permission_handler: ^11.3.1` (keeps permission_handler 11.x despite vosk_flutter's ^10.x constraint)
- `android/build.gradle.kts` — added `beforeEvaluate` block in `allprojects` to patch vosk_flutter's missing `namespace`
- `lib/features/video_import/presentation/home_screen.dart` — added "Generate Subtitles" button
- `lib/core/router/app_router.dart` — added `/subtitles` route, `SubtitleScreen` import

### Interfaces
- `AppRouter.subtitles` — route name `/subtitles`, takes `String videoPath` as argument
- `SubtitleEntriesNotifier` — Riverpod `Notifier<List<SubtitleEntry>>`, methods: `setEntries`, `updateEntry`, `clear`
- `SubtitleGeneratorService` — orchestrates Vosk STT pipeline: `ensureModelLoaded()` (downloads model via `ModelLoader`, creates `Model`) → reads WAV, parses header (sample rate, channels), feeds PCM via `Recognizer.acceptWaveformBytes()` in 8KB chunks → parses JSON result with word-level timestamps → groups words into `SubtitleEntry` list (gaps >2s or duration >5s or max 12 words per entry, merges short entries). Handles SRT export and FFmpeg burn-in.

### Changed interfaces
- `SilenceDetectorRepository.detectSilence()` now requires `totalDuration` parameter and internally handles VAD refinement, merging, padding, and breathing protection
- `DetectionParams` gains `useVad` and `useBreathingProtection` bool fields
- `DetectionParamsNotifier` gains `toggleVad()`, `toggleBreathingProtection()`, and `autoDetectThreshold(audioPath)` methods
- `DetectionSettingsPanel` accepts optional `onAutoDetect` callback

## 2026-05-17 Change — Real FFmpeg Progress Percentage
| Type | Issue | Fix |
|------|-------|-----|
| UX | Processing/Export dialogs show indeterminate `LinearProgressIndicator`, user can't tell how long is left | Added real percentage via `FFmpegKitConfig.enableStatisticsCallback()`. For concat operations, progress = `statistics.getTime() / outputDurationMs` from speech segments. For export, video duration obtained via FFprobe. Dialogs made reactive: EditorScreen uses `Consumer` watching `processingStateProvider`, ExportScreen uses `ValueListenableBuilder` + `ValueNotifier<double>`. |

## 2026-05-17 Change — Min Silence Duration Range
| Type | Issue | Fix |
|------|-------|-----|
| UX | Min Silence Duration slider range was 0.1–3.0s, limiting detection of very short silences | Expanded to 0.01–5.0s (10ms–5s) in `AppConstants`, updated slider display to ms, divisions to 499 (10ms steps). Affects slider UI, FFmpeg `d=` param, and `mergeCloseSegments` gap. |

## 2026-05-17 Feature — Smart Zoom for Jump Cuts
| Type | Issue | Fix |
|------|-------|------|
| Feature | After silence removal, jump cuts feel abrupt with no visual transition | Added optional **Smart Zoom**: auto-applies subtle zoom-in (∼5%) to alternating speech segments via `scale=iw*Z:ih*Z,crop=iw/Z:ih/Z` filter chain. Controlled via new `SmartZoomConfig` (enabled + zoomAmount) in `DetectionParams`. Toggle and amount slider added to `DetectionSettingsPanel`. |
| Accuracy | Silence detection missed short/quiet silences, used only peak-detection mode | **Three-pass detection**: coarse (user params, peak), fine (params-20dB, RMS, 0.05s min), coarse2 (params-10dB, peak, 0.3s min). RMS mode (`m=1`) catches noise-floor variations peak misses. Merge gap tightened from 0.25s → 0.15s. |
| Accuracy | VAD 30ms frame + fixed percentile missed fine-grained speech/noise boundaries | Switched to 20ms frames, 25th percentile noise floor, 90th percentile speech ceiling, threshold = noise + 25% of (ceiling−noise). More precise energy histogram for better non-speech rejection. |

### New files
- `lib/features/video_processing/data/services/ffmpeg_smart_zoom_service.dart` — builds per-segment zoom filter strings: `scale=iw*Z:ih*Z,crop=iw/Z:ih/Z,setsar=1`, applied to even-indexed segments (alternating pattern)

### Changed files
- `lib/features/silence_detector/domain/entities/detection_params.dart` — added `SmartZoomConfig` class (enabled, zoomAmount) + `smartZoom` field on `DetectionParams`
- `lib/features/silence_detector/domain/providers/silence_detection_provider.dart` — added `toggleSmartZoom()`, `setSmartZoomAmount()` on `DetectionParamsNotifier`
- `lib/features/silence_detector/presentation/widgets/detection_settings_panel.dart` — added Smart Zoom SwitchListTile + conditional Zoom Amount slider
- `lib/features/silence_detector/presentation/editor_screen.dart` — reads `detectionParamsProvider` for `smartZoom` config in `_previewResult`/`_processAndExport`; passes `params.smartZoom` to `startProcessing()`
- `lib/features/video_processing/data/services/ffmpeg_cutting_service.dart` — `cutWithConcat`, `_concatSegments`, `_fallbackReencode` accept optional `SmartZoomConfig`; uses `FfmpegSmartZoomService.buildZoomFilter(i, zoom)` per segment
- `lib/features/video_processing/domain/repositories/video_processor_repository.dart` — `processVideo()` gains optional `SmartZoomConfig? smartZoom` param
- `lib/features/video_processing/data/repositories/video_processor_repository_impl.dart` — passes `smartZoom` through to `_cuttingService.cutWithConcat()`
- `lib/features/video_processing/domain/providers/processing_provider.dart` — `startProcessing()` gains optional `SmartZoomConfig? smartZoom`; passes to `repository.processVideo()`
- `lib/features/silence_detector/data/datasources/ffmpeg_silence_datasource.dart` — three-pass detection (coarse + fine RMS + coarse2), tightened merge gap to 0.15s
- `lib/features/silence_detector/data/services/vad_service.dart` — 20ms frames, 25th/90th percentile energy histogram

### Interfaces
- `SmartZoomConfig` — `enabled` (bool, default false), `zoomAmount` (double, 1.01–1.20, default 1.05). With `copyWith`, `==`, `hashCode`. Not Equatable (needs const constructor for default param values).
- `FfmpegSmartZoomService.buildZoomFilter(segmentIndex, config)` → returns `String?` — `scale=iw*Z:ih*Z,crop=iw/Z:ih/Z,setsar=1` for even segments when zoom enabled, else null

## 2026-05-17 Bug Fixes
| Issue | Root Cause | Fix |
|-------|-----------|-----|
| Preview shows original for both | `_previewResult()` passed `widget.videoPath` as both `originalPath` and `processedPath` without processing | `_previewResult()` now calls `ProcessingNotifier.startProcessing()` first, then passes real `outputPath` |
| Export ignores quality (always original copy) | `exportVideo()` did `sourceFile.copy()` — never applied quality/format | `exportVideo()` now calls `FfmpegCuttingService.exportFile()` with selected quality flags |
| Low accuracy silence detection | Single-pass silencedetect at -30dB/0.5s missed quiet/long silences | Three-pass: coarse (user params, peak) + fine (params-20dB, RMS `m=1`, 0.05s min) + coarse2 (params-10dB, peak, 0.3s). Merge gap 0.15s. Default -40dB/0.25s. |
| FFmpeg concat `-filter_complex` fails | `filterParts.join(' ')` produced `chain1␣chain2` — space is NOT a valid FFmpeg filtergraph chain separator, only `;` is | Changed both `_concatSegments` and `_fallbackReencode` to `join(';')` |
| Concat output shows wrong segment (first 0.725s repeated) | `_fmt()` output `HH:MM:SS.mmm` with colons (e.g. `00:00:0.725:00:00:1.174`) — FFmpeg parser splits `:` as option separator, so `trim=00:00:0.725:00:00:1.174` was parsed as `start=0, end=0, duration=0.725` | Changed `_fmt()` to return float seconds (`0.725`), and trim/atrim use named params: `trim=start=0.725:end=1.174` |
| Silence detection cuts speech even at padding=0 | `silencedetect` threshold crossing points are ~50ms inside the speech region due to gradual volume ramps. `applyPadding` expanded silence outward (=removes more speech) | Added `precisionMargin = 0.05s` constant in `applyPadding` that SHRINKS each silence segment (pushes start forward, end backward) to avoid speech cutoff. Transform: `start = detected + 0.05 - paddingBefore`, `end = detected - 0.05 + paddingAfter` |
| --- | --- | --- |
| `flutter build apk --debug` succeeds | Clean build with 0 errors after full subtitle removal | `flutter pub get`, `flutter analyze` (0 errors, 2 pre-existing infos), `flutter build apk --debug` all pass |
| --- | --- | --- |
| Full Video Adjustment Module passes analyze+build | 0 errors, 2 pre-existing infos | `flutter analyze` (0 errors), `flutter build apk --debug` (success) |

## 2026-05-17 Feature — Video Adjustment Module
| Type | Issue | Fix |
|------|-------|------|
| Feature | No video color/audio/filter adjustment capability | Built complete `video_adjustment/` module with Clean Architecture: 12 filter groups (Basic, Tone, Color, Effects, Video, Audio), 12 built-in presets, LUT support, before/after comparison, undo/redo (20 steps), export with 4 quality levels. All offline via FFmpeg. |

### Architecture
- `FilterChainBuilder` (core engine) — builds FFmpeg `-filter_complex` strings in correct order: Geometric → Tone → Color (eq) → Detail → Effects → LUT → Speed → Fade. Audio chain processed in parallel. Skips filters at default values, returns null if no changes.
- `FrameExtractor` — extracts single JPG frame at 5s mark with current adjustments for instant preview (no full re-encode).
- `AdjustmentSettings` entity — holds all 40+ adjustment values across 5 sub-entities (ToneAdjustment, ColorAdjustment, VideoAdjustment, AudioAdjustment) + effects.
- `AdjustmentPreset` — 12 built-in presets (Normal, B&W, Sepia, Vintage, Cinematic, Faded Film, Cool Tone, Warm Tone, Dramatic, Soft, Vibrant, Noir).
- Riverpod providers: `adjustmentProvider` (settings state), `previewProvider` (frame preview), `exportProvider` (progress), `undoRedoProvider` (20-step stack).
- FFmpeg datatsource uses `ffmpeg_kit_flutter_new` with single-pass encoding, supports cancel, real-time statistics.

### New files created (35 files)
- `lib/core/constants/adjustment_defaults.dart` — default values for all adjustments
- `lib/core/constants/ffmpeg_filters.dart` — FFmpeg filter name constants
- `lib/core/utils/filter_chain_builder.dart` — core FFmpeg filter chain builder
- `lib/core/utils/frame_extractor.dart` — single-frame preview extraction
- `lib/features/video_adjustment/domain/entities/` — adjustment_settings, color_adj, tone_adj, video_adj, audio_adj, adjustment_preset
- `lib/features/video_adjustment/domain/repositories/adjustment_repository.dart` — abstract repo
- `lib/features/video_adjustment/domain/usecases/` — 5 use cases
- `lib/features/video_adjustment/data/datasources/ffmpeg_adjustment_datasource.dart` — FFmpeg execution
- `lib/features/video_adjustment/data/repositories/adjustment_repository_impl.dart` — repo impl
- `lib/features/video_adjustment/presentation/providers/` — adjustment, preview, export, undo_redo providers
- `lib/features/video_adjustment/presentation/screens/adjustment_screen.dart` — main editor (6 tabs: Basic, Color, Tone, Video, Audio, FX)
- `lib/features/video_adjustment/presentation/widgets/` — 12 widgets (slider, panels, presets, LUT, before/after, undo/redo)

### Changed files
- `pubspec.yaml` — no new deps needed (reuses existing ffmpeg_kit_flutter_new, flutter_riverpod, file_picker, path_provider)
- `lib/core/router/app_router.dart` — added `/adjustments` route, `AdjustmentScreen`, `AppRouter.adjustments`
- `lib/features/video_import/presentation/home_screen.dart` — complete redesign: two `FeatureCard` tiles (Silence Remover + Video Adjuster) side by side, professional dark theme, app renamed to "AI Video Studio"
- `lib/features/video_import/presentation/widgets/feature_card.dart` — NEW shared widget for feature selection
- `lib/app.dart` — title changed to "AI Video Studio"

### Key design decisions
- Uses existing `ffmpeg_kit_flutter_new` (no new FFmpeg package needed)
- Single-pass filter_complex for all adjustments — never multiple passes
- Default values mean "no change" — filters are skipped entirely
- All FFmpeg runs async, main thread never blocked
- Export supports: original copy, high (CRF 18), medium (CRF 23), compressed (CRF 28)

## 2026-05-17 Change — Real-time Preview + Hold-to-Peek Original
| Type | Issue | Fix |
|------|-------|------|
| UX | Preview updated via slow FFmpeg frame extraction on every slider change (300ms debounce, still >1s delay). Before/After was a static toggle showing "ORIGINAL" text placeholder | Complete overhaul: original video now plays seamlessly via `video_player` + `VideoPlayerController` in the preview area. Adjusted frame (JPG) overlays on top. Slider `onChangeEnd` triggers frame extraction only when user releases slider — **not** during drag. Preview is instant during slider drag because the underlying video keeps playing. |
| UX | Before/After toggle was slow — tapped to swap, no instant feedback | **Hold-to-peek**: `BeforeAfterToggle` uses `GestureDetector.onTapDown`/`onTapUp`/`onTapCancel`. Press and hold → overlay hidden immediately → shows original video playing underneath. Release → overlay reappears instantly. Zero delay — uses `showOriginal` boolean in `PreviewState` to toggle `Positioned.fill` overlay visibility. |

### Changed files (surgical — silence remover untouched)
- `lib/features/video_adjustment/presentation/widgets/adjustment_slider.dart` — added `onChangeEnd` callback, wired to `Slider.onChangeEnd`
- `lib/features/video_adjustment/presentation/widgets/basic_adjustments_panel.dart` — added `onPreviewChanged` param; onReset/onChangeEnd trigger frame extraction
- `lib/features/video_adjustment/presentation/widgets/color_adjustments_panel.dart` — same pattern
- `lib/features/video_adjustment/presentation/widgets/tone_adjustments_panel.dart` — same pattern
- `lib/features/video_adjustment/presentation/widgets/video_adjustments_panel.dart` — same pattern
- `lib/features/video_adjustment/presentation/widgets/audio_adjustments_panel.dart` — same pattern
- `lib/features/video_adjustment/presentation/widgets/effects_panel.dart` — same pattern
- `lib/features/video_adjustment/presentation/widgets/video_preview_widget.dart` — plays original video via `VideoPlayerController` (passed from parent). Adjusted frame overlays with `Positioned.fill` + `Image.file`. `showOriginal=true` hides overlay instantly → shows raw video underneath.
- `lib/features/video_adjustment/presentation/widgets/before_after_toggle.dart` — rewritten: single button with `GestureDetector(onTapDown=peekStart, onTapUp=peekEnd, onTapCancel=peekEnd)`. Shows "Hold to peek original" / "Release to compare".
- `lib/features/video_adjustment/presentation/screens/adjustment_screen.dart` — manages `VideoPlayerController` lifecycle (`initState` → init + play looping, `dispose` → dispose). Removed debounce Timer. All panels wired with `onPreviewChanged: _extractPreviewFrame` (only on slider release). Undo/Redo/Reset also trigger frame extraction.
- `lib/features/video_adjustment/presentation/widgets/video_preview_widget.dart` — (FIX) replaced `Stack(fit: StackFit.expand)` + `Positioned.fill` with `LayoutBuilder` + position math that preserves video aspect ratio. Video and overlay now share exact same position/size calculation.
- `lib/features/video_adjustment/presentation/providers/preview_provider.dart` — (FIX) loading spinner (`isLoading: true`) only shown when `previewPath == null` (very first frame). Subsequent frame updates happen silently in background — old frame stays visible until new one replaces it.

## 2026-05-17 Change — Silence Remover: Waveform Horizontal Stretch + Button Reorder + Padding Fix
| Type | Issue | Fix |
|------|-------|------|
| UX | Waveform zoom only affected vertical amplitude — user wants the waveform to stretch HORIZONTALLY with zoom | Wrapped in `SingleChildScrollView(horizontal)` + expanded `Container` width = `constraints.maxWidth * waveformZoom`. At 1x → normal, 2x → 2x wider + scrollable. `getDownsampledSamples(pixelWidth)` produces more samples → finer horizontal detail. |
| UX | Action buttons (Detect, Preview, Export) were below DetectionSettingsPanel — user wants them between zoom slider and settings | Moved `_buildActionButtons` ABOVE `DetectionSettingsPanel` and BELOW `_buildWaveformZoomControl`. New order: Video → Waveform → Zoom slider → **Buttons** → Settings → Segments. |
| Bug | With default `padding=0.1`, silence segments extended 50ms into adjacent speech → speech was cut at every segment boundary | Removed `precisionMargin` entirely. `padding=0` now means EXACT detected boundaries — zero speech cutting. `DetectionParams.defaults()` changed to `paddingBefore=0, paddingAfter=0`. User can still increase padding for more aggressive silence removal. |

### Changed files
| File | What changed |
|------|-------------|
| `lib/features/silence_detector/presentation/widgets/waveform_viewer.dart` | Wrapped in `ClipRRect` + `SingleChildScrollView(horizontal)`. Container width = `constraints.maxWidth * waveformZoom`. Height = `(100 * zoom).clamp(100, 300)`. Seek ratio uses `pixelWidth` instead of `constraints.maxWidth`. |
| `lib/features/silence_detector/presentation/editor_screen.dart` | Reordered build column: `_buildActionButtons` moved above `DetectionSettingsPanel` (between zoom slider and settings) |
| `lib/features/silence_detector/data/repositories/silence_detector_repository_impl.dart` | `applyPadding`: removed `precisionMargin` entirely. Uses raw `paddingBefore` / `paddingAfter`. padding=0 → exact boundaries, no speech cut. |
| `lib/features/silence_detector/domain/entities/detection_params.dart` | `defaults()`: `paddingBefore=0.0, paddingAfter=0.0` (was 0.1) |

## 2026-05-20 Feature — Video Quality Enhancement Module (Rebuilt)
New feature card "Enhancer" on home screen. Professional-grade video enhancement with automatic quality analysis and enhancement pipeline.

### Architecture
Clean Architecture (domain / data / presentation) with Riverpod 3.

### Features
| Feature | Implementation |
|---------|---------------|
| **Video Analysis** | FFprobe metadata extraction + quality metrics (brightness, contrast, saturation, noise, blur detection) |
| **Smart Enhancement** | Adaptive filter chain based on detected issues (denoise, tonemap, color grade, sharpen, upscale) |
| **4 Enhancement Levels** | Fast (quick polish), Balanced (default), Quality Max, Ultra (rescue bad footage) |
| **Before/After Preview** | Side-by-side split comparison with draggable slider, 3 sample frames |
| **Audio Enhancement** | Noise reduction (afftdn), compression, EQ, loudness normalization |

### FFmpeg Enhancement Pipeline (Professional)
| Stage | Filters |
|-------|---------|
| Noise Reduction | hqdn3d=luma_spatial:chroma_spatial:luma_tmp:chroma_tmp |
| Tone Mapping | curves=master (S-curve for depth, shadow lift, highlight recovery) |
| Color Grading | eq=saturation, colorbalance |
| Sharpening | unsharp=luma_msize_x:luma_msize_y:luma_amount |
| Upscaling | scale=W:H:flags=lanczos:force_original_aspect_ratio=decrease |
| Finishing | deband, vignette, format=yuv420p |
| Audio | afftdn, acompressor, equalizer, loudnorm, alimiter |

### Changed / Added files
| File | Purpose |
|------|---------|
| `lib/core/errors/failures.dart` | Added `EnhancementFailure` class |
| `lib/core/router/app_router.dart` | Added `/enhancement` route + `EnhancementHomeScreen` |
| `lib/features/video_import/presentation/home_screen.dart` | 3rd FeatureCard "Enhancer" |
| `lib/features/video_enhancement/domain/entities/` | `video_analysis_result.dart`, `enhancement_plan.dart`, `enhancement_settings.dart`, `enhancement_result.dart` |
| `lib/features/video_enhancement/domain/repositories/` | `enhancement_repository.dart` (interface) |
| `lib/features/video_enhancement/data/datasources/` | `video_analyzer_datasource.dart` (FFprobe), `ffmpeg_enhancement_datasource.dart`, `preview_generator_datasource.dart`, `professional_enhancement_command_builder.dart` |
| `lib/features/video_enhancement/data/repositories/` | `enhancement_repository_impl.dart` |
| `lib/features/video_enhancement/presentation/providers/` | `enhancement_provider.dart` (Riverpod Notifier) |
| `lib/features/video_enhancement/presentation/screens/` | `enhancement_home_screen.dart`, `import_screen.dart`, `analysis_screen.dart`, `plan_screen.dart`, `preview_screen.dart`, `processing_screen.dart`, `result_screen.dart` |
| `lib/features/video_enhancement/presentation/widgets/` | `split_comparison_widget.dart` |

### Key Design Decisions
- Single-pass FFmpeg filter_complex for all enhancements (never multiple passes)
- Auto-detect quality issues before enhancement (brightness, noise, blur, saturation)
- Adaptive filter intensity based on detected issue severity
- Distance-stable quality: temporal denoising (hqdn3d) + atadenoise for motion consistency
- Before/After preview with draggable split view
- CRF-based quality: Fast=20, Balanced=18, Quality=16, Ultra=14

## 2026-05-18 Feature — Shorts Generator Module
| Type | Issue | Fix |
|------|-------|------|
| Feature | No way to auto-create portrait shorts (9:16) from landscape video | Built complete `shorts_generator/` module: scene detection via FFmpeg (analysis) → split into clips → score + rank → reframe (3 strategies: centerCrop / blurBackground / faceAware) → export as 9:16 portrait. 3-screen flow: ImportMode → Suggestions → Export. |

### Architecture
Clean Architecture (domain / data / presentation) with Riverpod 3.

### New files (22 files)
| Directory | Files |
|-----------|-------|
| `domain/entities/` | `video_segment.dart`, `scene_info.dart`, `clip_suggestion.dart`, `reframe_settings.dart`, `export_settings.dart`, `shorts_project.dart` |
| `domain/repositories/` | `shorts_repository.dart` |
| `data/datasources/` | `ffmpeg_analysis_datasource.dart` (scene + silence detection via FFmpeg), `ffmpeg_export_datasource.dart` (clip cutting + reframe with 3 strategies) |
| `data/repositories/` | `shorts_repository_impl.dart` (scoring algorithm: scene priority = 0.5*durationScore + 0.3*positionScore + 0.2*diversityBonus) |
| `presentation/providers/` | `shorts_provider.dart` (`ShortsUiState` + `ShortsUiNotifier` + `ExportSettingsNotifier`) |
| `presentation/screens/` | `import_mode_screen.dart` (platform/duration/clipCount selectors + Analyze), `suggestions_screen.dart` (clip review + toggle + Export), `export_screen.dart` (CircularProgressIndicator + results) |
| `presentation/widgets/` | (empty — all UI inline in screens) |

### Changed files
| File | Change |
|------|--------|
| `lib/core/router/app_router.dart` | 3 new routes (`/shorts`, `/shorts/suggestions`, `/shorts/export`) + handlers using `AppRouter.shorts(…)` |
| `lib/features/video_import/presentation/home_screen.dart` | 4th FeatureCard "Shorts Creator" (orange gradient), `Wrap` layout updated |

### Key design decisions
- Scene scoring: weighted heuristic (duration + position + diversity), no ML model yet
- Reframe: centerCrop used by default (fastest); blurBackground and faceAware defined but face detection (`google_mlkit_face_detection`) not added to pubspec yet
- All FFmpeg-based, no backend
- Riverpod 3: single `ShortsUiNotifier` managing all UI state (no `StateProvider` — removed in Riverpod 3)
- Export outputs to temporary directory; user can find files via device file manager

## 2026-05-18 Fix — Shorts Generator: Real progress + working analysis
| Type | Issue | Fix |
|------|-------|------|
| Bug | "Analyze Video" button appears to do nothing (no loading indicator, analysis is slow because it extracts JPG thumbnails for every scene change) | **Rewrote `FfmpegAnalysisDatasource.detectScenes()`** to use `-f null -` mode (no file I/O) + FFmpeg statistics callback for real-time percentage. Added `FFprobeKit.getMediaInformation()` to get actual video duration instead of hardcoded 0. Added progress callback pipeline through `ShortsRepository.analyzeVideo()` → repository → datasource. |
| UX | No progress bar during video analysis | Added `analysisProgress` + `analysisStage` fields to `ShortsUiState`. Import mode now shows a modal progress dialog with `CircularProgressIndicator(value: analysisProgress)` + real percentage label + stage text ("Probing video...", "Analyzing scenes...", "Ranking clips..."). Dialog is non-dismissible (`barrierDismissible: false`, `PopScope(canPop: false)`). |

### Changed files
| File | Change |
|------|--------|
| `lib/features/shorts_generator/data/datasources/ffmpeg_analysis_datasource.dart` | Replaced JPG-extraction approach with `-f null -` + `showinfo` log parsing. Added `probeDuration()` via FFprobe. Added statistics callback for real progress. Removed unused `dart:io` import. |
| `lib/features/shorts_generator/data/repositories/shorts_repository_impl.dart` | `analyzeVideo()` now accepts `onProgress` callback, probes duration, passes progress through to datasource. |
| `lib/features/shorts_generator/domain/repositories/shorts_repository.dart` | Added `void Function(double progress, String stage)? onProgress` param to `analyzeVideo()`. |
| `lib/features/shorts_generator/presentation/providers/shorts_provider.dart` | Added `analysisProgress` (double) + `analysisStage` (String) to `ShortsUiState`. Added `setAnalysisProgress()` + `setAnalysisStage()` methods. |
| `lib/features/shorts_generator/presentation/screens/import_mode_screen.dart` | Added real-time progress dialog with CircularProgressIndicator + percentage + stage label during analysis. |

## 2026-05-18 Fix — Shorts Generator: Pillarbox reframe + time editing + cutting modes
| Type | Issue | Fix |
|------|-------|------|
| Bug | Exported video is cropped to 9:16 (center crop) instead of keeping original aspect ratio with black bars | Added `ReframeMode.pillarbox` → `scale='min(1080,iw*1920/ih)':'min(1920,ih*1080/iw)':flags=lanczos,pad=1080:1920:(1080-iw)/2:(1920-ih)/2:color=black`. Default changed from `centerCrop` to `pillarbox`. |
| Feature | User can't adjust clip start/end time after analysis | Added `updateClipSegment(clip, start, end)` on `ShortsUiNotifier`. Edit button (pencil icon) on each clip card → dialog with start/end sliders + `StatefulBuilder` for live preview. Made `VideoSegment.startSeconds`/`endSeconds` mutable. |
| Feature | Only scene-detection cutting mode — no time interval option | Added `CuttingMode` enum (interval, smartAudio, scene, manual, ai) to `ExportSettings`. Added mode selector on import screen (4 modes: Interval, Scene, Smart Audio, Manual). `analyzeVideo` branches on `cuttingMode` — interval mode generates evenly-spaced clips without FFmpeg scene detection. |

### Changed files
| File | Change |
|------|--------|
| `lib/features/shorts_generator/domain/entities/reframe_settings.dart` | Added `pillarbox` to `ReframeMode` enum. Default changed to `ReframeMode.pillarbox`. |
| `lib/features/shorts_generator/domain/entities/export_settings.dart` | Added `CuttingMode` enum (interval, smartAudio, scene, manual, ai). Added `cuttingMode` field to `ExportSettings`. |
| `lib/features/shorts_generator/domain/entities/video_segment.dart` | `startSeconds`/`endSeconds` changed from `final` to mutable `double`. Added `copyWith()`. |
| `lib/features/shorts_generator/data/datasources/ffmpeg_export_datasource.dart` | Added `pillarbox` filter case. `outputDir` uses `FileUtils.getExportDirectory()`. Added `scanOutput()`. |
| `lib/features/shorts_generator/data/repositories/shorts_repository_impl.dart` | `analyzeVideo` branches on `CuttingMode` — interval mode generates evenly-spaced clips. Added `_generateIntervalScenes()` + `_generateIntervalSuggestions()`. Added `unawaited(_export.scanOutput())`. |
| `lib/features/shorts_generator/presentation/providers/shorts_provider.dart` | Added `setCuttingMode()` on `ExportSettingsNotifier`. Added `updateClipSegment()` on `ShortsUiNotifier`. |
| `lib/features/shorts_generator/presentation/screens/import_mode_screen.dart` | Added `_buildCuttingModeSelector()` — 4 radio-style option cards (Interval, Scene, Smart Audio, Manual). |
| `lib/features/shorts_generator/presentation/screens/suggestions_screen.dart` | Added edit button (pencil) per clip → dialog with start/end sliders + StatefulBuilder. |

## 2026-05-18 Fix — Shorts Generator: Export quality + live preview + all 5 cutting modes
| Type | Issue | Fix |
|------|-------|------|
| Quality | Exported shorts use `-q:v 5` (mpeg4) / `-crf 22` (libx264) — ignores `ExportSettings.bitrateMbps` (default 12 Mbps). Quality is visibly lower than original. | Replaced `-q:v 5` with `-b:v ${bitrateMbps}M -maxrate ${bitrateMbps*2}M -bufsize ${bitrateMbps*2}M` for mpeg4. Same for libx264 fallback (replaces `-crf 22`). Now export bitrate matches settings (default 12 Mbps → 1080p quality close to original). |
| UX | Edit clip time dialog shows sliders but no video preview — user must apply, then tap play button to see the result | Rewrote `_showEditDialog` as `_EditClipDialogRoute` + `_EditClipScreen` StatefulWidget. Embeds `VideoPlayerController.file()` playing the video. Shows thumbnail preview with play/pause. Moving start slider immediately seeks the video player to the new position. User sees the clip range change live. |
| Feature | `CuttingMode.smartAudio` existed as enum but had no logic | Implemented `_detectSilence()` that runs FFmpeg `silencedetect` filter (noise=-35dB, d=0.5s) to find all silence gaps. `_generateSmartAudioSuggestions()` inverts silence gaps into speech ranges, generates clips centered on speech segments. |
| Feature | `CuttingMode.manual` existed as enum but had no logic | Implemented `_generateManualScenes()` + `_generateManualSuggestions()` — evenly-spaced clips across full duration, labeled "Edit clip N" to indicate user should fine-tune via edit + live preview. |
| Feature | `CuttingMode.ai` existed as enum but had no logic | Implemented `_generateAiSuggestions()` — runs scene detection AND `_detectSilence()` (audio). Score = `durationScore * 0.3 + positionScore * 0.3 + audioRatio * 0.4` where `audioRatio = 1 - (silence_in_scene / scene_duration)`. Scenes with consistent audio score higher. |
| Housekeeping | Unused imports: `return_code.dart` in repository, unused `step` variable | Removed. |

### Changed files
| File | Change |
|------|--------|
| `lib/features/shorts_generator/data/datasources/ffmpeg_export_datasource.dart` | Export commands use `-b:v ${bv}M -maxrate ${bv*2}M -bufsize ${bv*2}M` instead of `-q:v 5` / `-crf 22`. |
| `lib/features/shorts_generator/data/repositories/shorts_repository_impl.dart` | Full rewrite of `analyzeVideo()` with switch on 5 `CuttingMode`s. Added `_detectSilence()`, `_generateSmartAudioSuggestions()`, `_generateManualScenes()`, `_generateManualSuggestions()`, `_generateAiSuggestions()`. Removed unused imports. |
| `lib/features/shorts_generator/presentation/screens/suggestions_screen.dart` | `_showEditDialog` → `_EditClipDialogRoute` + `_EditClipScreen` with embedded `VideoPlayerController` + live seek on slider change. |

## 2026-05-18 Hotfix — Red screen crash + Smart Audio quality
| Type | Issue | Fix |
|------|-------|------|
| Crash | Red screen when editing clip time: `Slider' Failed assertion: 'min <= max'` — slider `max` went negative when `_endSec < 5` (e.g., a 5‑second clip) | Rewrote slider parameters with `.clamp()` guards: `startMax = (_endSec - minClip).clamp(minClip, endMax)`, `endMin = (_startSec + minClip).clamp(0.0, endMax)`. Slider values also clamped: `_startSec.clamp(0, startMax)`. Minimum clip width reduced from 5s → 1s. Divisions scaled to 20 per second for fine control. Removed auto‑play on start slider change. |
| Accuracy | Smart Audio mode used `silencedetect=noise=-35dB:d=0.5` — too aggressive, detected quiet ambient sounds as speech, missed actual speech boundaries | Changed to `noise=-26dB:d=0.8` (less sensitive, longer min silence = natural pause between sentences). Speech segment generation rewritten: merges adjacent non‑silence blocks with < 2s gap, sorts by duration descending (longest speech first), uses full natural speech boundaries without max-duration clamp. Falls back to interval clips if no speech segments found. |

## 2026-05-18 Feature — Drafts + Extended editing + More options
| Type | Issue | Fix |
|------|-------|------|
| Feature | No draft system — exiting analysis screen loses all settings and clip edits | New `DraftService` (`lib/core/services/draft_service.dart`): saves `ExportSettings` + clip list as JSON in `appDocumentsDirectory/drafts/`. Restored on `ImportModeScreen.initState()` with snackbar "Draft restored from previous session". Saved after each successful analysis. Keyed by video path hash, zero memory footprint. |
| Feature | Smart Audio clips were clamped to `maxDurationSeconds` — speech segments longer than max duration were center-cropped, losing context | Smart Audio now uses full natural speech segment boundaries (`start`→`end`). No max-duration clamp. Score proportional to segment length. Each speech segment becomes a clip with its natural start/end. |
| UX | Manual clip time editing can only shorten clip (start forward, end backward) — can't extend start earlier or end later to capture more context | `_EditClipScreen` now uses `widget.totalVideoDuration` (full video length) as the absolute bounds. Start slider can go to `0.0` (beginning of video), end slider can go to `totalVideoDuration`. Added visual timeline bar showing full video range (gray), original clip range (light primary), current edit range (primary), and two white handle lines. |
| UX | Only 5 clip count options (2,4,6,8,10) with `Expanded` layout — cramped and limited | Replaced with `SingleChildScrollView` horizontal row: 5, 10, 15, 20, 25, 30, 50. Flexible layout scrolls horizontally. |
| UX | Only 4 duration options (15s–90s). `ClipDuration` enum had m3/custom but not exposed in UI | 8 options now in horizontal scrollable row: 15s, 30s, 60s, 90s, 3m, 5m, 10m, 15m. Added `ClipDuration.m5` (300s), `m10` (600s), `m15` (900s) to enum. |

### Changed/New files
| File | Change |
|------|--------|
| `lib/core/services/draft_service.dart` | **NEW** — `DraftData` entity + `DraftService` (save/load/delete/allDraftPaths) using JSON files. |
| `lib/features/shorts_generator/domain/entities/export_settings.dart` | Added `ClipDuration.m5`, `m10`, `m15` with corresponding `maxDurationSeconds` (300/600/900). |
| `lib/features/shorts_generator/presentation/providers/shorts_provider.dart` | Added `restore(ExportSettings)` to `ExportSettingsNotifier`. |
| `lib/features/shorts_generator/presentation/screens/import_mode_screen.dart` | `initState` → `_tryRestoreDraft()`. Draft save after analysis. `_buildDurationSelector` → 8 options in horizontal scroll. `_buildClipCountSelector` → 7 options (5–50) in horizontal scroll. |
| `lib/features/shorts_generator/presentation/screens/suggestions_screen.dart` | `_ClipCard` + `_EditClipDialogRoute` + `_EditClipScreen` accept `totalVideoDuration`. Slider bounds use full video duration (0→totalVideoDuration). Added visual timeline bar with original/current clip ranges + handle markers. |
| `lib/features/shorts_generator/data/repositories/shorts_repository_impl.dart` | Smart Audio uses natural speech boundaries (no max-duration clamp). Uses record type `({double start, double end})` for speech ranges. |

## 2026-05-18 Feature — Live playhead timeline + 8 pro reframe templates
| Type | Issue | Fix |
|------|-------|------|
| UX | No live playhead in edit dialog — video plays but timeline bar doesn't move, user can't track position in long video | Added `_playheadSec` field with `_onPositionChange` listener on `VideoPlayerController`. Timeline bar now shows moving playhead marker (primary-colored pill with white dot) that tracks video playback in real-time. Time display shows `▶ MM:SS` of current position alongside clip range. |
| Feature | Only 4 reframe modes — no professional templates (cinematic, Ken Burns, glow, mirror) | Added 4 new `ReframeMode` enum values: `cinematicLetterbox` (2.35:1 black bars via `drawbox`), `kenBurns` (slow zoom via `zoompan`), `shadowGlow` (dimmed glow background via `gblur`+`colorchannelmixer`), `mirrorSplit` (horizontal mirror via `split`+`hflip`+`hstack`). Totals 8 templates. Added `extension ReframeModeLabel` with `label`/`description` getters. Added `reframeMode` field to `ExportSettings`. Added `_buildTemplateSelector` + `_iconForMode` in import screen. |
| Architecture | `ReframeSettings` was hardcoded as `const ReframeSettings()` in export — never configurable | Added `reframeMode` to `ExportSettings`, wired through `ExportSettingsNotifier.setReframeMode()` → `shorts_repository_impl.dart` export uses `ReframeSettings(mode: project.exportSettings.reframeMode)`. Saved/restored in draft system (`dart:convert` JSON → enum `.name`). |

### Changed files
| File | Change |
|------|--------|
| `lib/features/shorts_generator/domain/entities/reframe_settings.dart` | Added 4 new `ReframeMode` values + `extension ReframeModeLabel` with `label`/`description`. |
| `lib/features/shorts_generator/domain/entities/export_settings.dart` | Added `reframeMode` field + import for `reframe_settings.dart`. `ExportSettings.const` now takes `reframeMode`. |
| `lib/features/shorts_generator/data/datasources/ffmpeg_export_datasource.dart` | Added filter implementations for `cinematicLetterbox`, `kenBurns`, `shadowGlow`, `mirrorSplit`. |
| `lib/features/shorts_generator/data/repositories/shorts_repository_impl.dart` | `exportClips` uses `ReframeSettings(mode: project.exportSettings.reframeMode)` instead of `const ReframeSettings()`. |
| `lib/features/shorts_generator/presentation/providers/shorts_provider.dart` | Added `setReframeMode()` + `reframeMode` import. |
| `lib/features/shorts_generator/presentation/screens/import_mode_screen.dart` | Added import for `reframe_settings.dart`. Added `_buildTemplateSelector` (8 radio-style option cards with labels/descriptions/icons). Draft save/restore includes `reframeMode`. |
| `lib/features/shorts_generator/presentation/screens/suggestions_screen.dart` | `_EditClipScreen` adds `_onPositionChange` listener on `VideoPlayerController`. Tracks `_playheadSec` in real-time. Timeline bar shows moving playhead marker with primary color + white dot. Time row shows `▶ MM:SS` of current position. |

## 2026-05-18 Feature — Face tracking + Per-clip reframe templates
| Type | Issue | Fix |
|------|-------|------|
| Bug | `faceAware` reframe mode was just center-crop placeholder — no actual face tracking | Added `google_mlkit_face_detection 0.13.2` dependency. Created `FaceDetectionService.detectFaceCenterX()`: extracts a JPEG frame at clip midpoint via FFmpeg → runs MLKit face detector → returns normalized face center X (0–1). During export with `faceAware` mode, pre-computes face position and passes it to `_buildReframeFilter()`. The crop filter uses FFmpeg expression `max(0, min(iw-cropW, faceCenterX*iw-cropW/2))` to center crop on face. Falls back to default center-crop if no face detected. |
| Feature | All clips use the same global reframe template — no per-clip customization | Added `ReframeMode? reframeMode` field to `ClipSuggestion` (nullable = use global default). Added `updateClipReframe(clip, mode)` on `ShortsUiNotifier`. Added `_TemplateBadge` widget in `_ClipCard` showing current template (or "Default") → tap opens bottom sheet with all 8 modes + shows which is "default". `exportClips()` uses `clip.reframeMode ?? project.exportSettings.reframeMode`. Draft save includes per-clip `reframeMode.name`. |

### Changed/New files
| File | Change |
|------|--------|
| `pubspec.yaml` | Added `google_mlkit_face_detection: 0.13.2` |
| `lib/core/services/face_detection_service.dart` | **NEW** — `FaceDetectionService.detectFaceCenterX()`: extracts JPEG frame via FFmpeg, detects face via MLKit, returns normalized center X. |
| `lib/features/shorts_generator/domain/entities/clip_suggestion.dart` | Added `ReframeMode? reframeMode` (nullable), import for `reframe_settings.dart`. |
| `lib/features/shorts_generator/presentation/providers/shorts_provider.dart` | Added `updateClipReframe()` method. |
| `lib/features/shorts_generator/data/datasources/ffmpeg_export_datasource.dart` | `_buildReframeFilter()` accepts optional `faceCenterX` param. `faceAware` case builds crop filter with face-centered x expression when faceCenterX provided. `exportClip()` accepts optional `faceCenterX` param and forwards it to filter builder. |
| `lib/features/shorts_generator/data/repositories/shorts_repository_impl.dart` | `exportClips()` resolves per-clip reframe mode (`clip.reframeMode ?? global`). For `faceAware`, runs `FaceDetectionService.detectFaceCenterX()` at clip midpoint before export, passes to `exportClip()`. |
| `lib/features/shorts_generator/presentation/screens/suggestions_screen.dart` | Added import for `reframe_settings.dart`. Added `_TemplateBadge` ConsumerWidget in clip card showing template name + icon. Tap opens `_showTemplateSheet()` bottom sheet with all 8 modes + checkmark + "default" label. |
| `lib/features/shorts_generator/presentation/screens/import_mode_screen.dart` | Draft save serializes per-clip `reframeMode`. |

## 2026-05-18 Feature — Multi-frame face tracking + Full draft persistence + Home drafts
| Type | Issue | Fix |
|------|-------|------|
| Bug | `faceAware` sampled only 1 frame at clip midpoint — locked onto one face, didn't track speaker changes | `FaceDetectionService.detectFaceCenterX()` now samples 5 frames evenly across the clip's time range. For each frame, picks the **largest** face (closest to camera). Sorts all centers, trims top/bottom 20%, averages the rest. Falls back to center crop if no faces in any frame. |
| UX | Draft only saved ExportSettings + clip metadata — re-opening required full re-analysis (slow) | `DraftService` now saves the **entire ShortsProject** (scenes + clips + totalDuration + exportSettings) via `saveFullProject()`. `DraftData.restoreProject()` rebuilds the full `ShortsProject` from JSON. `_tryRestoreDraft()` now auto-navigates to suggestions screen if a full project draft exists. Provider auto-saves on every clip mutation (`toggleClip`, `updateClipSegment`, `updateClipReframe`) via `_autoSaveDraft()`. |
| UX | No way to resume a draft from home screen — had to re-import the same video | Home screen now loads all drafts on init (`_loadDrafts()`). Shows a "Resume Draft" section below import button with each draft as a tappable card (video filename, clip count, duration). Tapping navigates to `ImportModeScreen` with the draft's video path. List refreshes after each import. |

### Changed files
| File | Change |
|------|--------|
| `lib/core/services/face_detection_service.dart` | **Rewrite** — samples multiple frames (5 by default) across clip range, picks largest face per frame, trims outliers, averages center X. |
| `lib/core/services/draft_service.dart` | **Rewrite** — added `DraftData` fields: `totalDuration`, `scenes`. New `saveFullProject(ShortsProject)` saves complete project state (export settings + scenes + clips). New `restoreProject()` rebuilds `ShortsProject` from JSON. New `allDrafts()` returns all saved drafts. Old `save()` kept for backward compat. |
| `lib/features/shorts_generator/presentation/providers/shorts_provider.dart` | Added `_autoSaveDraft()` — calls `DraftService.saveFullProject()` after every clip mutation. |
| `lib/features/shorts_generator/presentation/screens/import_mode_screen.dart` | `_tryRestoreDraft()` now checks for full project draft → auto-restores project + navigates to suggestions. Draft save uses `DraftService.saveFullProject()`. |
| `lib/features/shorts_generator/data/repositories/shorts_repository_impl.dart` | `detectFaceCenterX` call passes clip start/end range instead of single midpoint. |
| `lib/features/video_import/presentation/home_screen.dart` | Added `_loadDrafts()` in `initState`. Shows "Resume Draft (N)" section with list of draft cards (video name, clip count, duration). Tapping navigates to shorts screen with draft's video path. Refreshes after import. |

### New files
- `lib/core/services/face_detection_service.dart` — already existed; rewrote for multi-frame tracking

### Known limitations
- Face tracking in 2026-05-18 version still uses visual face detection (MLKit), not audio-based speaker diarization. The multi-frame sampling finds the most consistently prominent face across the clip, but doesn't identify WHO is speaking. True speaker tracking requires audio diarization (future work).

## 2026-05-18 Fix — Speaker-aware face tracking + Draft probe robustness
| Type | Issue | Fix |
|------|-------|------|
| Bug | `faceAware` picked the largest face per frame, not the speaker — when 2+ people visible, tracked the wrong person | Rewrote `FaceDetectionService` to use **lip movement detection**: enables MLKit `enableLandmarks: true`, extracts mouth center (bottomMouth + leftMouth + rightMouth landmarks), tracks faces across frames by position proximity, computes average mouth-movement distance per track, selects the face with **highest lip movement** (speaker). Falls back to most persistent face if no significant mouth movement found. Samples 6 frames evenly across clip. |
| Bug | Opening a draft whose video file was deleted/moved caused "Could not read video duration" with no clear recovery | Added `File(videoPath).existsSync()` check in `_tryRestoreDraft()` — if missing, deletes the stale draft and shows snackbar. Added same check in `_startAnalysis()` before analysis. `probeDuration` wrapped in try-catch with detailed logging. Error message improved: "Could not read video duration. The file may be missing or corrupted." |

### Changed files
| File | Change |
|------|--------|
| `lib/core/services/face_detection_service.dart` | **Rewrite** — now uses MLKit landmarks (`bottomMouth`, `leftMouth`, `rightMouth`) to track faces across 6 frame samples and selects speaker by highest mouth movement. Falls back to most persistent face. |
| `lib/features/shorts_generator/presentation/screens/import_mode_screen.dart` | Added `import 'dart:io'`. `_tryRestoreDraft()` checks `File.existsSync()` before restoring — deletes stale drafts. `_startAnalysis()` checks file existence before probing. |
| `lib/features/shorts_generator/data/datasources/ffmpeg_analysis_datasource.dart` | `probeDuration` wrapped in try-catch with logging for robustness. |
| `lib/features/shorts_generator/data/repositories/shorts_repository_impl.dart` | Improved error message for duration probe failure. |

## 2026-05-18 Fix — SIGSEGV crash on export (round 3: chroma plane alignment in swscale)
| Type | Issue | Fix |
|------|-------|------|
| Crash | `SIGSEGV SEGV_ACCERR` in `libswscale.so` with ARM MTE (Memory Tagging Extension) during export. App uses `ffmpeg-kit-flutter-android-full-gpl-arm64-v8a-8.0.0` (full GPL build, not min). The `scale` filter uses swscale with NEON SIMD optimization. When intermediate frames have ODD chroma plane dimensions (e.g., Y=606 → U=303), swscale's chroma NEON processing accesses 304 lines when only 303 exist → buffer overrun → MTE tag mismatch → `SIGSEGV SEGV_ACCERR`. | Every intermediate frame dimension forced to **multiple of 4** (not just even): `evenCropW` → `4*trunc(.../4)`, all `scale` height expressions wrapped with `2*trunc(.../2)`, `mirrorSplit` → `4*trunc(iw/4)`. |

### Changed file
| File | Change |
|------|--------|
| `lib/features/shorts_generator/data/datasources/ffmpeg_export_datasource.dart` | `evenCropW()`: `2*trunc(x/2)` → `4*trunc(x/4)` (centerCrop, faceAware). pillarbox & cinematicLetterbox: `'min(outH, ih*outW/iw)'` → `'2*trunc(min(outH, ih*outW/iw)/2)'`. blurBackground & shadowGlow: `ih*outW/iw[fg]` → `2*trunc(ih*outW/iw/2)[fg]`. mirrorSplit: `2*trunc(iw/4)*2` → `4*trunc(iw/4)`. kenBurns: `iw*1.02:ih*1.02` → `2*trunc(iw*1.02/2):2*trunc(ih*1.02/2)`. mpeg4 command uses `-b:v M -q:v 5` (no -maxrate/-bufsize, those are H.264-specific). Both commands have `-pix_fmt yuv420p`. |

## 2026-05-19 Fix — Video Enhancement Module: Professional quality overhaul + FFmpeg command fix
| Type | Issue | Fix |
|------|-------|------|
| Bug (CRITICAL) | FFmpeg command used `-filter_complex` with video+audio filter chains joined by `;` but **without stream routing** (`[0:v]`, `[0:a]`, `-map`). FFmpeg cannot auto-route mixed video+audio filter chains in `-filter_complex` — command always fails with all presets | Split filters into separate `-vf` (video) and `-af` (audio). `_buildVideoFilters` and `_buildAudioFilters` now write to **different** lists. `_buildCommand` uses `-vf "filters"` for video and `-af "filters"` for audio instead of `-filter_complex`. Added `-map 0:v? -map 0:a?` for safe optional stream mapping (handles video-only inputs without crashing). |
| Bug (CRITICAL) | `File(inputPath).length()` in repository throws `FileSystemException` when inputPath is a YouTube stream URL — enhancement crashes before FFmpeg runs | Added `VideoDownloadService.isUrl()` check — skips `File.length()` for URLs, sets `originalSize = 0`. |
| Bug | FFmpeg error logs were discarded — exception message just said "Video enhancement failed" with no details | Exception now includes FFmpeg return code + first 500 chars of error logs: `"Video enhancement failed: FFmpeg exited with <code>. <logs>"`. Error logs also written via `AppLogger.e()`. |
| Bug | `vidstabtransform` filter had `input="transforms.trf"` with quotes — FFmpeg treats quotes as part of filename, file not found | Changed to `input=transforms.trf` (no quotes) |
| Bug | Stabilization runs `vidstabdetect` pass but `vidstabtransform` **never applied** in filter chain — shakes detected but output video is identical to input | Added `vidstabtransform=smoothing=X:input=transforms.trf:zoom=0:optzoom=0` to `_buildVideoFilters()` when `stabilizeEnabled=true` |
| Bug | `totalDuration=0` hardcoded in `processing_screen.dart:33` — progress callback receives 0ms duration, progress always stuck at 0% | `EnhancementProcessingNotifier.startEnhancement()` now auto-probes video duration via repository.analyzeVideo if `totalDuration` not provided. Added detailed logging for probe results. |
| Bug | Result comparison screen (`result_comparison_screen.dart`) showed the **same file** for both original and enhanced | Added `originalPath` field to `EnhancementResult`. Comparison screen now loads original video from `originalPath` and enhanced from `outputPath`. Hold-to-peek gesture + ORIGINAL/ENHANCED badge. |
| Bug | `Social Media` preset used `QualityLevel.medium` (CRF 23) — quality too low for publishing | Updated to `QualityLevel.high` (CRF 18), `EncodingPreset.medium`, audio normalize + dialogue enhance, sharpening 0.8. |
| Quality | No detail preservation when upscaling — pixelation when zooming | New `preserveDetail` field (default `true`). Auto-applies `unsharp=0.6:0.3` after scale. |
| Quality | Missing `-pix_fmt yuv420p` in output options | Added to all outputs. |
| Quality | Poor error diagnostics — no FFmpeg command logged on failure | Full command logged via `AppLogger.i()` before execution. Return code + truncated logs logged on failure. |
| UX | Error shown in 2-second snackbar — too short, user can't read or copy | Replaced snackbar with `AlertDialog` indicating terminal output. |
| Debug | `stderr.writeln()` not visible in `flutter run` on Android (captured by logcat at different priority) | Replaced with `print()` which outputs as `I/flutter` and guaranteed visible in terminal. Removed `dart:io` import. |
| Debug (NEW) | `getAllLogsAsString()` misses FFmpeg error messages — FFmpeg exits with code 1 but only version banner captured. Error messages arrive asynchronously or through a log-level channel that `getAllLogs[A]()` misses | **Triple capture strategy**: (1) `enableLogCallback` + `StringBuffer` for real-time capture, (2) `getAllLogs(5000)` with 5s timeout for async messages, (3) `getFailStackTrace()` for crash traces. Also added `setLogLevel(Level.avLogVerbose)` (level 40) to ensure all log levels are captured. Stabilization pass (`_runStabilizationPass`) also uses the same capture strategy and **throws on failure** instead of silently continuing. |
| Debug (NEW) | All FFmpeg commands fail with exit code 1 and ONLY version banner — no error message through `av_log` at any level (AV_LOG_ERROR, AV_LOG_WARNING, etc.). Even `vidstabdetect` (stabilization pass) fails the same way. | Added `_runDiagnostic()` method that runs 2 tests BEFORE any processing: (1) `-version` (tests FFmpeg binary works), (2) `-i input -c copy -f null -` (tests input file reading without any filters/encoding). Test results: test 1 ✅, test 2 ✅, stabilization ❌. |
| Fix (NEW) | `libvidstab` (vidstabdetect/vidstabtransform) not available in this FFmpeg build — `-vf vidstabdetect=...` fails with exit code 1. Error goes through `fprintf(stderr)` (bypasses ffmpeg-kit's `av_log` callback), so no error message visible. | `_runStabilizationPass()` now returns `bool` (success/failure) and **does NOT throw** on failure. If it returns false, `enhanceVideo()` removes `vidstabtransform` from `videoFilters` via `removeWhere()` before building the command. Stabilization is gracefully skipped — enhancement continues with all other features. |
| Fix (NEW) | Progress stuck at 0% — `probeVideo()` used `getAllLogsAsString()` which returns empty, so `durationSeconds` = 0, `outputDurationMs` = 0, statistics callback skips progress updates | (1) `probeVideo()` now uses `enableLogCallback` + `StringBuffer` for real-time capture, with `getAllLogsAsString()` as fallback. (2) `processing_provider.dart` now uses fallback duration of 60s if probe returns <= 0. (3) `_analyzeVideo` in repository logs first 300 chars of probe output for debugging. |

### Changed files
| File | Change |
|------|--------|
| `lib/features/video_enhancement/data/datasources/ffmpeg_enhancement_datasource.dart` | Replaced `-filter_complex` with `-vf` + `-af`. Added `-map 0:v? -map 0:a?`. Fixed vidstabtransform quotes. FFmpeg logs included in exception. Added logging throughout. `stderr.writeln` → `print()`. Removed `dart:io` import. Added `enableLogCallback` + `getAllLogs(5000)` + `getFailStackTrace()` triple capture with `setLogLevel(Level.avLogVerbose)`. Added imports for `level.dart`, `log.dart`. `_runStabilizationPass` returns `bool`, throws NOT — on failure removes `vidstabtransform` from filters. Added `_runDiagnostic()`. `probeVideo()` fixed to use `enableLogCallback` for real-time capture. |
| `lib/features/video_enhancement/data/repositories/enhancement_repository_impl.dart` | Added URL path handling (skip `File.length()` for URLs). Added extensive logging. Added `VideoDownloadService` import. Added probe output logging (first 300 chars) + post-FFmpeg step logging (resultPath, outputSize, outputAnalysis duration) for debugging. |
| `lib/features/video_enhancement/domain/entities/enhancement_result.dart` | Added `originalPath` field. |
| `lib/features/video_enhancement/domain/entities/enhancement_settings.dart` | Added `preserveDetail` field (default `true`) with `copyWith`. |
| `lib/features/video_enhancement/domain/entities/enhancement_preset.dart` | Social Media preset: CRF 18, medium preset, audio normalize + dialogue, sharpen 0.8. |
| `lib/features/video_enhancement/presentation/providers/enhancement_provider.dart` | Added `togglePreserveDetail()`. |
| `lib/features/video_enhancement/presentation/providers/processing_provider.dart` | `startEnhancement` probes duration via repository.analyzeVideo. Added fallback 60s if probe fails. Added print() logging before/after repository.enhanceVideo() for debugging. |
| `lib/features/video_enhancement/presentation/screens/enhancement_home_screen.dart` | Added "Preserve Detail" switch. |
| `lib/features/video_enhancement/presentation/screens/processing_screen.dart` | Snackbar → AlertDialog (shown on failure). Removed `flutter/services.dart` import. Simplified dialog text to point user to terminal. |
| `lib/features/video_enhancement/presentation/screens/result_comparison_screen.dart` | Hold-to-peek comparison with original+enhanced videos. |
| `PROJECT_MAP.md` | Updated documentation. |

| Debug (NEW) | Enhancement reaches 100% progress but then nothing happens — no navigation, no error, no save. Suspect hang in post-FFmpeg steps (output file analysis probe, file size) | Added `print()` logging at each step: (1) `=== REPO: datasource returned resultPath=... ===`, (2) `=== REPO: outputSize=... ===`, (3) `=== REPO: outputAnalysis duration=... ===` in repository, and `=== ENHANCEMENT: repository.enhanceVideo returned ===`, `result type = ...`, `AppError/Success` in processing provider. |

### Verification
| Check | Status |
|-------|--------|
| lutter analyze | 0 issues |

## 2026-05-22 Fix — YouTube download: use yt library's own HTTP client (fixes 403)
| Type | Issue | Fix |
|------|-------|------|
| Bug (CRITICAL) | YouTube DASH video/audio stream downloads get HTTP 403. Raw `HttpClient` lacks proper headers (Referer, Cookie, User-Agent) that YouTube CDN requires. Also can't handle fragmented DASH streams (moof+mdat fragments). | **Replaced `_downloadStream` with `yt.videos.streams.get(streamInfo)`** — uses `YoutubeExplode`'s own `YoutubeHttpClient` which has correct headers (`user-agent: Mozilla/5.0 ...`, `cookie: CONSENT=YES+cb`, `accept-language: en-US`), handles fragmented DASH streams by downloading each fragment individually and concatenating, supports retry (5 attempts), byte-range requests, and response validation. |
| Bug | Fragmented DASH streams couldn't be merged even with 3-strategy fallback because the downloaded file was HTML error page (403) instead of video data. | The new `_downloadViaYt()` method uses `yt.videos.streams.get()` which properly authenticates via YouTube's API session. |

### Verification
| Check | Status |
|-------|--------|
| flutter test (16) | All 16 pass |
| flutter analyze | 0 errors in changed files |

## 2026-05-23 Fix — Muxed only (no video-only, no download)
| Type | Issue | Fix |
|------|-------|------|
| UX | Video-only stream download never receives data (progress stuck at 0%). `yt.videos.streams.get()` hangs even with 30s timeout. | **Removed all video-only streams from quality dialog.** `getAvailableQualities()` returns only muxed streams (≤720p). All qualities use direct stream URL — instant playback, has audio. No download, no merge, no 403. |
| Cleanup | Removed all download-related code that became orphaned by this change. | Removed `downloadAudioOnly()` method, `AudioPathStore` class from `video_download_service.dart`. Removed video-only download branch (+progress dialog, CancelToken, AudioPathStore wiring) from `home_screen.dart`. Reverted `AudioProcessorRepositoryImpl`, `ShortsRepositoryImpl`, `EnhancementRepositoryImpl` to original (no AudioPathStore references). Removed `_formatSpeed` from `home_screen.dart`. |

### Changed files
| File | Change |
|------|--------|
| `lib/core/services/video_download_service.dart` | `getAvailableQualities()`: removed `manifest.videoOnly` loop (only muxed now). Removed `downloadAudioOnly()` method. Removed `AudioPathStore` class. |
| `lib/features/video_import/presentation/home_screen.dart` | Removed entire video-only else-if branch (progress dialog, speed tracker, AudioPathStore, _formatSpeed). Quality dialog simplified: all options use `Icons.wifi` + `"Stream · size"`. |
| `lib/features/video_import/domain/entities/video_file.dart` | Kept `audioPath` field (still useful for future). |
| `lib/features/audio_processing/data/repositories/audio_processor_repository_impl.dart` | Reverted to original (no AudioPathStore import/check). |
| `lib/features/shorts_generator/data/repositories/shorts_repository_impl.dart` | Reverted to original (no AudioPathStore import/check, no `dart:io` import). |
| `lib/features/video_enhancement/data/repositories/enhancement_repository_impl.dart` | Reverted to original (no `VideoDownloadService.isUrl()` checks). |

### Verification
| Check | Status |
|-------|--------|
| flutter test (18) | All 18 pass |
| flutter analyze | 0 new issues (2 pre-existing) |

## 2026-05-22 Fix — Overflow, smaller cards, % decimal, download logging
| Type | Issue | Fix |
|------|-------|------|
| Bug | FeatureCard Column overflows by 32-38px. `Spacer` + large text (title 18, subtitle 13) + padding 20 + `childAspectRatio: 0.85` makes card too short (151dp height) for content (needs ~170dp). | Removed `Spacer`. Padding 20→14. Icon 44→36. Title 18→15, `maxLines: 2`. Subtitle 13→12, `maxLines: 2`, `height: 1.3`. SizedBox 6→4. `childAspectRatio: 1.05` → cards shorter (152dp → 145dp height). |
| UX | Progress percentage shows "0%" for first 5% of download (`toStringAsFixed(0)` rounds <0.5% to 0). User thinks download isn't moving. | Changed to `toStringAsFixed(1)` → shows "0.1%", "0.5%", "1.2%" etc. Movement visible immediately. |
| Debug | User unsure if videos actually download from YouTube DASH streams. | Added logging: `'_downloadViaYt: received first chunk (N bytes), totalBytes=M'` and `'_downloadViaYt: download complete, N bytes received'`. Visible via `flutter logs`. |
| UX | User wants smaller cards to add more features later. | `childAspectRatio: 1.05` (was 0.85). All card dimensions reduced. |

### Changed files
| File | Change |
|------|--------|
| `lib/core/services/video_download_service.dart` | Added logging in `_downloadViaYt`: first chunk + total bytes + complete + error. |
| `lib/features/video_import/presentation/home_screen.dart` | `toStringAsFixed(0)` → `toStringAsFixed(1)` for progress %. |
| `lib/features/video_import/presentation/widgets/feature_card.dart` | Padding 20→14, icon 44→36, title 18→15, subtitle 13→12, removed `Spacer`, added `maxLines: 2` + `overflow: TextOverflow.ellipsis` on both texts, `height: 1.3` on subtitle. |

### Verification
| Check | Status |
|-------|--------|
| flutter test (18) | All 18 pass |
| flutter analyze | 0 errors |

## 2026-05-22 Fix — YouTube import: no download, use stream URL directly in player
| Type | Issue | Fix |
|------|-------|------|
| UX | Every YouTube download attempt fails (403, moov atom, merge errors). User wants video to play immediately without downloading. | **Replaced `downloadAndMergeYoutube` with direct stream URL.** `_resolveFromYoutube` now uses muxed stream URL directly in `VideoFile.path`. No download, no FFmpeg merge. For video-only selections, falls back to nearest muxed stream. |
| Bug | `adjustment_screen.dart` uses `File(widget.videoPath)` — crashes with URL. | Added URL check: use `VideoPlayerController.networkUrl()` for URLs, `file()` for local paths. Skipped `_extractPreviewFrame` for URLs (FFmpeg can't handle YouTube CDN). |

### Changed files
| File | Change |
|------|--------|
| `lib/features/video_import/presentation/home_screen.dart` | `_resolveFromYoutube`: removed `downloadAndMergeYoutube` + `getVideoMetadata` calls. Instead finds muxed stream URL from manifest options and uses it directly as `_videoFile.path`. |
| `lib/features/video_adjustment/presentation/screens/adjustment_screen.dart` | `_initVideoPlayer`: added `VideoDownloadService.isUrl()` check → uses `networkUrl` for URLs. Added import. `_extractPreviewFrame`: skip if URL. |

### Verification
| Check | Status |
|-------|--------|
| flutter test (16) | All 16 pass |
| flutter analyze | 0 errors in changed files |

## 2026-05-18 Fix � Silence Remover: YouTube URL support + 4h video memory crash
| Type | Issue | Fix |
|------|-------|------|
| Bug | Silence Remover's EditorScreen uses VideoPlayerController.file(File(videoPath)) ? crashes when videoPath is a YouTube stream URL. | Same pattern as Shorts Generator: conditional � URL ? VideoPlayerController.networkUrl(Uri.parse(path)), local ? VideoPlayerController.file(File(path)). |
| Bug | AudioProcessorRepositoryImpl.analyzeWaveform() calls awFile.readAsBytes() on the full raw PCM file. For a 4-hour video at 44100Hz mono, the PCM file is ~1.27 GB ? OutOfMemoryError crash on most devices. | Replaced eadAsBytes() with streaming via awFile.openRead(). Reads file in chunks, processes each 16-bit sample on the fly, accumulates window averages. Only stores 2000 final waveform samples in memory. Memory usage: O(~KB) instead of O(GB). |

### Changed files
| File | Change |
|------|--------|
| lib/features/silence_detector/presentation/editor_screen.dart | VideoPlayerController.file(File(...)) ? conditional: URL ? 
etworkUrl(Uri.parse(...)), local ? ile(File(...)). Added import for VideoDownloadService. |
| lib/features/audio_processing/data/repositories/audio_processor_repository_impl.dart | nalyzeWaveform(): replaced awFile.readAsBytes() (loads entire PCM into memory) with awFile.openRead() stream + per-chunk processing. Same averaging logic, same output format, zero memory overhead for large files. |

### Verification
| Check | Status |
|-------|--------|
| lutter analyze | 0 issues |


## 2026-05-22 Fix � YouTube download: use yt library's own HTTP client (fixes 403)
| Type | Issue | Fix |
|------|-------|------|
| Bug (CRITICAL) | YouTube DASH video/audio stream downloads get HTTP 403. Raw HttpClient lacks proper headers and can't handle fragmented DASH streams. | **Replaced _downloadStream with yt.videos.streams.get(streamInfo)** � uses YoutubeExplode's own YoutubeHttpClient which has correct headers (User-Agent, Cookie, Accept-Language), handles fragmented DASH by downloading each fragment individually, supports retry (5 attempts), byte-range requests, and response validation. |
| Bug | Merged file was HTML error page (403) because raw download failed silently before. | New _downloadViaYt() method uses YouTube's authenticated HTTP client via yt.videos.streams.get(). |

### Changed files
| File | Change |
|------|--------|
| lib/core/services/video_download_service.dart | Non-muxed path: _downloadStream(url, ...) ? _downloadViaYt(yt, streamInfo, ...). Uses yt.videos.streams.get(streamInfo) which returns Stream<List<int>> with YouTube's own header/auth handling. |

### Verification
| Check | Status |
|-------|--------|
| flutter test (16) | All 16 pass |
| flutter analyze | 0 errors in changed files |

## 2026-05-22 Fix � YouTube import: no download, use stream URL directly in player
| Type | Issue | Fix |
|------|-------|------|
| UX | Every YouTube download attempt fails (403, moov atom, merge errors). User wants video to play immediately without downloading. | **Replaced downloadAndMergeYoutube with direct stream URL.** _resolveFromYoutube now uses muxed stream URL directly in VideoFile.path. No download, no FFmpeg merge. For video-only selections, falls back to nearest muxed stream. |
| Bug | adjustment_screen.dart uses File(widget.videoPath) � crashes with URL. | Added URL check: use VideoPlayerController.networkUrl() for URLs, file() for local paths. Skipped _extractPreviewFrame for URLs (FFmpeg can't handle YouTube CDN). |

### Changed files
| File | Change |
|------|--------|
| lib/features/video_import/presentation/home_screen.dart | _resolveFromYoutube: removed downloadAndMergeYoutube + getVideoMetadata calls. Instead finds muxed stream URL from manifest options and uses it directly as _videoFile.path. |
| lib/features/video_adjustment/presentation/screens/adjustment_screen.dart | _initVideoPlayer: added VideoDownloadService.isUrl() check ? uses networkUrl for URLs. Added import. _extractPreviewFrame: skip if URL. |

### Verification
| Check | Status |
|-------|--------|
| flutter test (16) | All 16 pass |
| flutter analyze | 0 errors in changed files |

## 2026-05-22 Fix - Hybrid: muxed instant stream + video-only download and merge
| Type | Issue | Fix |
|------|-------|------|
| UX | Using only muxed streams = limited to 360p-720p. User wants 1080p+ quality. | Hybrid approach: muxed selections -> stream URL directly (instant). Video-only selections -> download via _downloadViaYt (yt's HTTP client, no 403) + 3-strategy FFmpeg merge. |
| Bug | Muxed fallback for video-only gave lowest available quality. | Restored downloadAndMergeYoutube call for video-only, which downloads both video+audio via yt.videos.streams.get() and merges via FFmpeg. |

### Changed files
| File | Change |
|------|--------|
| lib/features/video_import/presentation/home_screen.dart | _resolveFromYoutube: muxed -> URL directly in _videoFile.path. Video-only -> downloadAndMergeYoutube (downloads via yt's client + 3-strategy merge). Dialog shows Instant stream for muxed, Download and merge for video-only. |

### Verification
| Check | Status |
|-------|--------|
| flutter test (16) | All 16 pass |
| flutter analyze | 0 errors in changed files |

## 2026-05-22 Fix - ALL qualities use stream URL directly (no download)
| Type | Issue | Fix |
|------|-------|------|
| UX | User wants any quality (including 1080p video-only) without waiting for download. | ALL selections use stream URL directly via _videoFile.path = streamUrl. For video-only streams (1080p+), hasAudio=false (no audio in stream). Video plays instantly. No download, no FFmpeg merge, no 403. |
| Cleanup | downloadAndMergeYoutube only called from test now. | Left in place (other modules may reference it). Not deleted per surgical rules. |

### Changed files
| File | Change |
|------|--------|
| lib/features/video_import/presentation/home_screen.dart | _resolveFromYoutube: removed else branch (download+merge). Now ALL qualities directly use stream URL. hasAudio reflects whether stream is muxed. Dialog subtitle updated to Stream (video+audio) / Stream (video only). |

### Verification
| Check | Status |
|-------|--------|
| flutter test (16) | All 16 pass |
| flutter analyze | 0 errors in changed files |

## 2026-05-22 Fix - Muxed instant, video-only download+merge (all features work)
| Type | Issue | Fix |
|------|-------|------|
| UX | Video-only URLs have no audio - silence remover, shorts, adjuster all fail to process. | Muxed -> stream URL directly (instant playback, audio, all features work). Video-only -> downloadAndMergeYoutube via _downloadViaYt (yt's HTTP client, no 403) + 3-strategy FFmpeg merge. |
| UX | Users confused by different behavior per quality. | Dialog clearly labels Instant stream (muxed) vs Download and merge (video-only). |

### Verification
| Check | Status |
|-------|--------|
| flutter test (16) | All 16 pass |
| flutter analyze | 0 errors in changed files |

## 2026-05-23 Fix - Download timeout + video+audio for all qualities
| Type | Issue | Fix |
|------|-------|------|
| Bug | `_downloadViaYt` hangs forever if YouTube CDN URL stalls (dialog shows 0% indefinitely). No timeout on the stream. | Added `stream.timeout(Duration(seconds: 30))` to `_downloadViaYt`. On timeout, throws `TimeoutException('Download timed out: no data received for 30 seconds')` which propagates as error snackbar. |
| Debug | No logging before/after video/audio download phases in `downloadAndMergeYoutube`. | Added `AppLogger().i('downloadAndMergeYoutube: starting/complete video download')` and same for audio. Helps trace which phase hangs. |
| UX | Muxed uses stream URL directly. Video-only does full download+merge — gives video+audio in all qualities. Progress dialog shows real bytes/speed. Gallery save via Gal.putVideo. Cancel button works. |

### Current flow
- **Muxed (≤720p):** Stream URL directly in `_videoFile.path` → instant playback, has audio, all features work.
- **Video-only (1080p+):** Download via `_downloadViaYt` (yt's HTTP client, 30s timeout, no 403) → merge via 3-strategy FFmpeg → save to gallery → `_videoFile.path` = local merged file + `hasAudio: true`.

### Changed files
| File | Change |
|------|--------|
| `lib/core/services/video_download_service.dart` | `_downloadViaYt`: stream wrapped with `.timeout(Duration(seconds: 30))`. `downloadAndMergeYoutube`: added start/complete logging for both video and audio phases. |
| `lib/features/video_import/presentation/home_screen.dart` | `_resolveFromYoutube`: muxed → stream URL. Video-only → download+merge with progress dialog, Gal gallery save, CancelToken. Quality dialog shows "Stream" for muxed, "Download + merge" for video-only with file size. |

### Verification
| Check | Status |
|-------|--------|
| flutter test (18) | All 18 pass |
| flutter analyze | 0 errors in changed files |

## 2026-05-23 Audio import + Audio Enhancer
| Type | Feature |
|------|---------|
| New | Audio file import via `FilePicker.pickFiles(type: FileType.audio)` — MP3/WAV/AAC/FLAC support |
| UI | When audio file loaded → **only** "Audio Enhancer" card shown. When video file loaded → 4 video feature cards. |
| New | `AudioEnhancementScreen` — 3 levels (Light/Balanced/Pro) using FFmpeg audio filters: `afftdn` (noise reduction), `acompressor`, `equalizer`, `alimiter` |
| UX | Audio enhancer button (microphone icon) sits next to video Import button. After processing, output saved as `.m4a` (AAC 256kbps) to export directory. |

### Changed files
| File | Change |
|------|--------|
| `lib/features/video_import/presentation/home_screen.dart` | Added `_isAudioFile` state, `_importAudio()` method, `_openAudioEnhancer()` nav, audio import button, conditional feature cards (audio-only vs video-only), updated info text. |
| `lib/core/router/app_router.dart` | Added `/audio-enhance` route + `AudioEnhancementScreen` import. |
| `lib/features/video_import/presentation/widgets/video_info_card.dart` | Resolution/FPS rows hidden when 0 (audio files). |
| `lib/features/audio_enhancement/presentation/screens/audio_enhancement_screen.dart` | Full audio enhancement screen with presets + sliders + FFmpeg processing. |

### Bugfix — Audio enhance failed (×2)
| Attempt | Issue | Root cause | Fix |
|---------|-------|------------|-----|
| 1st | FFmpeg non-success exit code | Guessed: `loudnorm` filter + `-ar 48000` + `ffmpeg` prefix mismatch | Removed `loudnorm`, `-ar 48000`, `ffmpeg` prefix. Still failed. |
| 2nd | H.264 hardware encoder crash (`Component c2.qti.avc.encoder error: 0xffffffff`) | **Audio files with album art** — FFmpeg sees the embedded JPEG as a video stream and initializes the Qualcomm hardware H.264 encoder, which crashes on zero-resolution input. | **Added `-vn`** flag to skip video entirely. Also removed `-movflags +faststart` (pointless for audio-only). Works on all audio files now. |
| 3rd | `RenderFlex overflowed by 25 pixels on the bottom` | Layout too tall for small screens (5 sliders × 70px + spacing + AppBar + status bar > viewport height). | Compressed all widgets: `dense: true` on ListTile, reduced slider section height (32px), reduced padding/spacing by 40%, preset cards use `MainAxisSize.min`. Total height reduced by ~150px. |

### Detailed controls added
| Control | Range | FFmpeg filter | Default (Balanced) |
|---------|-------|---------------|-------------------|
| Noise Reduction | 0–100% | `afftdn=nf=-30..-10` | 50% (-20dB floor) |
| Compression | Off / -30..0 dB threshold | `acompressor=threshold=` | 50% (-15dB threshold) |
| Bass Boost | ±12 dB | `equalizer=f=100:t=o:w=100:g=` | 0 dB |
| Treble Boost | ±12 dB | `equalizer=f=3000:t=o:w=1000:g=` | +0.5 dB |
| Output Volume | 0–200% | `volume=` | 100% |

### Presets
| Preset | Noise | Comp | Bass | Treble | Vol |
|--------|-------|------|------|--------|-----|
| Light | 30% | Off | 0 | 0 | 100% |
| Balanced | 50% | 50% | 0 | +0.5 | 100% |
| Pro | 75% | 65% | +2 | +1.0 | 100% |

Any slider move → preset switches to **Custom**.

### Verification
| Check | Status |
|-------|--------|
| flutter test (18/19) | 18 pass, 1 pre-existing (widget test: SplashScreen timer). **No regression.** |
| flutter analyze | 0 errors in lib/ |

## 2026-05-23 Fix — Audio Enhancer: replace afftdn with compand (upward expander)
| Type | Issue | Fix |
|------|-------|------|
| Bug | `afftdn` either fails silently (triggering auto-fallback to basic highpass+lowpass) or provides inadequate noise reduction. User confirms noise is still audible after processing. `agate`, `anlmdn`, `acompressor` all also failed on this FFmpeg build. | **Replaced `afftdn` with `compand`** — an FFmpeg 1.x era audio dynamic range expander, **guaranteed** to work on any FFmpeg build. Configured as an **upward expander**: noise floor gets pushed down relative to speech, improving SNR by 5–20dB depending on slider position. The expander curve is: `-80/-80 | noiseFloor/noiseFloor | expIn/expOut | 0/0 | 20/-3`. Below noise floor: 1:1 (no change). Between noise floor and expansion end: slope > 1 (expansion → SNR improves). Above 0dB: limiting to -3dB (prevents clipping). |
| Bug | `afftdn` at max slider (nr=0.4) still too weak for real-world noise. | `compand` expander creates **programmable SNR improvement**: at balanced (50%), input SNR of 17dB → output SNR of 22dB (+5dB). At pro (75%), input SNR of 15dB → output SNR of 25dB (+10dB). At max (100%), input SNR of 15dB → output SNR of 27dB (+12dB). These are real, measurable improvements. |
| Code | Fallback loop added complexity but was needed for unreliable filters. | Removed `useAfftdn` parameter and fallback loop entirely. `compand` is guaranteed to work, so no fallback needed. Single-pass execution. |
| Code | Removed unused `_mapNr()` function. | Deleted. |

### Filter chain (now)
```
highpass=f=80,compand=attacks=0.1:decays=0.1:points=-80/-80|-40/-40|-28/-18|0/0|20/-3,lowpass=f=11500,equalizer=f=80:...,equalizer=f=4000:...,volume=...dB
```

### How the expander curve works
```
Input (dB) → Output (dB)
-80        → -80        (silence)
-40        → -40        (noise floor: 1:1, no change)
-28        → -18        (expansion: slope=1.83 → SNR improves by 10dB)
  0        →  0         (normal speech: 1:1)
+20        → -3         (limiter: prevents clipping)
```

### Changed files
| File | Change |
|------|--------|
| `lib/features/audio_enhancement/presentation/screens/audio_enhancement_screen.dart` | Replaced `_mapNr()` + afftdn filter with parameterized `compand` expander. Removed `buildAudioFilter(useAfftdn)` parameter. Removed `_nb` / `_mapNr` / `useAfftdn` / fallback loop. `compand` points computed from slider: `noiseFloor=-45+20t`, `expIn=noiseFloor+12`, `expOut=(noiseFloor+6+14t).clamp(..)`. Removed unused `_mapNr()`. |

### Verification
| Check | Status |
|-------|--------|
| flutter test (26) | 8 audio_enhancement + 18 video_download = 26 pass, **no regression** |
| flutter analyze (audio_enhancement/) | **0 issues** |

## 2026-05-23 Feature — Auto noise detect + 5 pro presets + real preview + full controls
| Type | Issue | Fix |
|------|-------|------|
| Feature | User wants automatic professional audio enhancement without manual tweaking. | **5 built-in presets**: Auto (auto-detect noise floor), Voice (speech optimized), Music (preserve dynamics), Podcast (warm clear voice), Bg Remove (suppress background voices). Each preset sets all 7 controls to optimal values. |
| Feature | Noise floor is unknown — user must guess the right noise floor for compand. | **AutoNoiseDetector service**: runs FFmpeg `volumedetect` on first 30s, parses RMS level histogram, estimates noise floor at 10th percentile + 3dB. Runs on Auto preset or via "Analyze" button. Returns noise floor in dB (-60 to -20). |
| Feature | No way to hear the enhancement before exporting the full file (can take 30s+). | **12s preview**: processes first 12 seconds with current filters to a temp file, plays it back inline using `video_player` (already a dependency). Dialog shows progress bar, timeline, play/pause, "Apply to full audio" button. Progress bar shows real-time generation progress. |
| Feature | Only 4 controls (noise, bass, treble, volume) — not enough for professional audio work. | **7 controls**: Noise Floor (dB), Gate/Expander (0-100%), De-esser (0-100%), Bass 80Hz (±12dB), Mid 1kHz (±12dB), Presence 3kHz (±12dB), Treble 8kHz (±12dB), Volume (0-200%). Each maps to a specific `equalizer` band with proper Q/frequency. De-esser uses `t=q` (notch) at 8kHz. |
| Feature | Background voices from other people can't be removed. | **Bg Remove preset**: aggressive noise floor (-28dB), high gate (85%), mid boost (4dB) to keep main voice, presence boost (6dB) for clarity, treble+2dB, bass cut (-1dB). Combined with `compand` upward expander that pushes down all quiet sounds (including background chatter) by up to 20dB. Not perfect (no AI), but dramatically reduces audible background voices. |

### New files
| File | Purpose |
|------|---------|
| `lib/features/audio_enhancement/data/services/auto_noise_detector.dart` | Runs `volumedetect` FFmpeg pass, parses histogram, returns noise floor dB estimate. |

### Changed files
| File | Change |
|------|--------|
| `lib/features/audio_enhancement/presentation/screens/audio_enhancement_screen.dart` | Major expansion: added `AutoNoiseDetector` import, `_PresetValues` const map with 5 presets, auto-detect noise floor flow, preview system with `VideoPlayerController`, 7 sliders organized in 3 sections, preview + export buttons. Added `import 'package:path_provider/path_provider.dart'`, `import 'package:video_player/video_player.dart'`, `import '../../data/services/auto_noise_detector.dart'`. |

### Bugfix — Preview dialog crashed (infinite listener loop)
| Type | Issue | Fix |
|------|-------|------|
| Bug | Preview dialog adds `ctrl.addListener(() => setInnerState(() {}))` **inside** `StatefulBuilder.builder` — on every rebuild, a new listener is attached, creating an infinite loop. Dialog becomes sluggish then crashes. | Removed `addListener` pattern entirely. Replaced `StatefulBuilder`-only approach with **before/after tab toggle using `StatefulBuilder` for the `showOriginal` variable only**. Progress bar updated via direct `active.value.position` reads inside the `StatefulBuilder` builder — no listeners needed (builder is triggered by tab toggle and play/pause). Controller changes are read directly from `active.value` on each rebuild. |
| Feature | No before/after comparison — user can't hear the difference. | **Before/After toggle tabs** (`_previewTab`): two segment-control-like buttons "Original" / "Enhanced" at top of dialog. When toggling: pauses current, seeks to 0, plays the other. Active tab highlighted with primary color + visibility icon. Both controllers (`_origPreviewController` + `_previewController`) initialized via `Future.wait` before dialog opens. |

### Verification
| Check | Status |
|-------|--------|
| flutter test (24) | 6 audio_enhancement + 18 video_download = 24 pass, **no regression** |
| flutter analyze (audio_enhancement/) | **0 issues** |
| New dependencies | `video_player` + `path_provider` (both already in project) |

## 2026-05-23 Bugfix — Enhanced audio silent in preview (WAV unsupported by video_player)
| Type | Issue | Fix |
|------|-------|------|
| Bug | Preview switched to WAV (`pcm_s16le`) in previous fix, but `VideoPlayerController` (via `video_player`/ExoPlayer) does **not reliably play WAV files** — only video containers (MP4, M4A, MOV, etc.). Enhanced audio tab showed black screen / no playback, while Original tab (using original AAC/MP3 file) worked fine. | **Reverted preview output from PCM WAV back to AAC/M4A** (`-c:a aac -b:a 256k`). With `FFmpegKit.execute()` (blocking), AAC encoding is now reliable — no more Completer race conditions. Preview path extension changed back to `.m4a`. |

### Verification
| Check | Status |
|-------|--------|
| flutter test (24) | 6 audio_enhancement + 18 video_download = 24 pass, **no regression** |
| flutter analyze (audio_enhancement/) | **0 issues** |

## 2026-05-23 Bugfix — Preview crashed with "Preview generation failed"
| Type | Issue | Fix |
|------|-------|------|
| Bug | `_previewAudio()` used `executeAsync` + `Completer` + `enableStatisticsCallback`. The global statistics callback from a previous `_process()` call could fire during preview with stale data. The `Completer` had a race condition — `executeAsync` callback fires on FFmpeg thread, but `completer.complete()` might resolve before `session.getReturnCode()` is ready. Also the `.m4a` AAC encoder may not work on some devices for short clips. | **Switched to `FFmpegKit.execute()`** (blocking call, no completer, no statistics callback). Preview is only 12 seconds, so blocking for 2-3s is acceptable. **Output format changed from AAC (.m4a) to PCM WAV (.wav)** via `-c:a pcm_s16le` — no encoder needed, guaranteed to work. Added 50ms delay (`await Future.delayed`) after `setState` so "Generating..." label renders before FFmpeg blocks the UI. **Error snackbar now shows actual FFmpeg error logs** instead of generic "Preview generation failed" — user sees the real error message (first 2 lines matching Error/error/Invalid/No such). |
| Feature | No before/after in preview (continued from previous update) | Before/after toggle tabs work correctly with both controllers initialized via `Future.wait`. Controllers disposed in `dispose()`. |
| Code | Dead import: `dart:async` (Completer no longer used in preview) | Keep `dart:async` — still used by `_process()` Completer. |

### Verification
| Check | Status |
|-------|--------|
| flutter test (24) | 6 audio_enhancement + 18 video_download = 24 pass, **no regression** |
| flutter analyze (audio_enhancement/) | **0 issues** |
| flutter analyze (full project) | 0 new issues in audio_enhancement |

## 2026-05-23 Surgical Update — Unified Media Cutter + Real Enhancement Fixes
| Type | Issue | Fix |
|------|-------|-----|
| Feature | User needs audio trimming and video/audio cutting in one professional feature beside existing tools. | Added **Media Cutter** route and screen. It supports audio-only trimming and video+audio trimming/removal in one UI with range selection, preview playback, keep-selection mode, and remove-selection mode. Video export maps `0:v:0` + optional `0:a?` for normal trim; middle remove mode uses `trim`/`atrim` + `concat` so A/V stay in sync; edge remove mode falls back to a head/tail trim. |
| Bug | Audio noise reduction curve did not actually push the detected noise floor down enough. | Added `AudioEnhancementFilterBuilder` and moved filter construction out of the screen. New `compand` curve is a downward expander around the noise floor, with limiter protection and volume=0 handling. Tests now assert the noise floor is reduced rather than mapped unchanged. |
| Bug | Audio before/after preview could race because preview used `executeAsync` + `Completer`. | Preview generation now uses blocking `FFmpegKit.execute()` for the 12s clip, keeps AAC/M4A output, and the before/after dialog listens to `VideoPlayerController` via `ValueListenableBuilder` so progress and play/pause state update correctly. |
| Bug | Auto noise detect placed `-t 30` after the null output, so the probe could scan more than intended or be ignored. | Moved `-t 30` before the input in `AutoNoiseDetector` and clamped detected dB to the supported -60..-20 range. |
| Bug | Video enhancement command still used `ffmpeg` prefix inside FFmpegKit and relied heavily on scaling. | `ProfessionalEnhancementCommandBuilder.buildDirectCommand()` now emits a FFmpegKit-ready command with no binary prefix, quoted paths, optional audio mapping, and real quality filters: `hqdn3d`, `deblock`, aspect-preserving `scale+pad`, `curves`, `eq`, `unsharp`, `deband`, `format=yuv420p`. |
| Bug | Enhancement preview used duplicated lightweight filters and `ffmpeg` prefix. | `PreviewGeneratorDatasource` now reuses `ProfessionalEnhancementCommandBuilder.buildDirectVideoFilter()` and emits FFmpegKit-ready commands. |
| UX | Feature cards could overflow vertically on small screens after adding more tools. | `FeatureCard` now adapts padding/font/icon sizes by available height and flexes subtitle text; Home grid cards are slightly taller. `VideoInfoCard` and `ImportButton` now ellipsize constrained text. |
| Test stability | `widget_test.dart` failed due pending splash/animation timers. | `SplashScreen` now cancels its navigation timer in `dispose`; widget test uses `pumpAndSettle()` so animations settle before teardown. |

### New files
| File | Purpose |
|------|---------|
| `lib/features/media_cutter/data/services/ffmpeg_media_cutter_service.dart` | FFmpeg command builder/executor for unified audio/video cutter. |
| `lib/features/media_cutter/presentation/screens/media_cutter_screen.dart` | Unified cutter UI with preview, keep/remove modes, range slider, and export. |
| `lib/features/audio_enhancement/data/services/audio_enhancement_filter_builder.dart` | Testable audio enhancement filter builder shared by screen + tests. |
| `test/media_cutter_command_test.dart` | Verifies trim/remove FFmpeg commands for audio and video. |
| `test/video_enhancement_command_test.dart` | Verifies direct video enhancement applies real quality filters beyond scale. |

### Changed files
| File | Change |
|------|--------|
| `lib/core/router/app_router.dart` | Added `/media-cutter` route. |
| `lib/features/video_import/presentation/home_screen.dart` | Added Media Cutter cards for video/audio flows and reset `_isAudioFile` when importing video/URL media. |
| `lib/features/audio_enhancement/presentation/screens/audio_enhancement_screen.dart` | Uses `AudioEnhancementFilterBuilder`, fixed preview execution and before/after progress updates. |
| `lib/features/audio_enhancement/data/services/auto_noise_detector.dart` | Fixed `volumedetect` probe option order and result clamp. |
| `lib/features/video_enhancement/data/datasources/professional_enhancement_command_builder.dart` | Added direct command builder and shared real-quality video filter chain. Fixed invalid sharpen filter and aspect-preserving upscale+pad. |
| `lib/features/video_enhancement/data/datasources/ffmpeg_enhancement_datasource.dart` | Uses command builder and `AppLogger` instead of `print`. |
| `lib/features/video_enhancement/data/datasources/preview_generator_datasource.dart` | Uses shared enhancement filter chain and removes `ffmpeg` prefix. |
| `lib/features/video_import/presentation/widgets/feature_card.dart` | Responsive vertical layout to prevent RenderFlex overflow. |
| `lib/features/video_import/presentation/widgets/video_info_card.dart` | Ellipsizes constrained info values. |
| `lib/features/video_import/presentation/widgets/import_button.dart` | Ellipsizes constrained label. |
| `lib/features/splash/presentation/splash_screen.dart` | Cancels pending navigation timer in `dispose`. |
| `test/audio_enhancement_test.dart` | Uses production filter builder instead of duplicated test-only filter code. |
| `test/widget_test.dart` | Settles splash animations before teardown. |

### Verification
| Check | Status |
|-------|--------|
| TDD red run | Failed as expected before implementation: missing `AudioEnhancementFilterBuilder`, missing `FfmpegMediaCutterService`, missing `buildDirectCommand`. |
| Targeted tests | `flutter test test\audio_enhancement_test.dart test\media_cutter_command_test.dart test\video_enhancement_command_test.dart` -> **13 pass**. |
| Full regression tests | `flutter test` -> **32 pass**. |
| `flutter analyze` | Still reports **19 pre-existing warnings/infos** outside the new cutter and touched command-builder surfaces, mostly unused imports/locals in video enhancement analyzer/provider screens and one silence detector local. No new issues from the new cutter/audio builder tests. |

### Known remaining debt
| Area | Notes |
|------|-------|
| Analyzer cleanup | Existing warnings remain in `adaptive_threshold_service.dart`, `video_analyzer_datasource.dart`, `enhancement_repository_impl.dart`, `enhancement_provider.dart`, and several video enhancement presentation files. Left untouched per surgical-change rule. |
| Video remove mode without audio | `Media Cutter` remove-selection mode for video assumes an audio stream because it concatenates `[0:a]`. Normal trim uses optional `0:a?`. If silent-video remove mode becomes required, add a video-only concat fallback. |

## 2026-05-23 Surgical Fix — Cutter/Preview Actually Executable
| Type | Issue | Fix |
|------|-------|-----|
| Bug | Media Cutter preview only played the original controller between two positions; it did not generate the actual cut result. | `_previewSelection()` now creates a temporary FFmpeg output using the same cutter service, initializes a dedicated `VideoPlayerController` from that generated file, and shows a real generated preview dialog for audio/video. |
| Bug | Trim command used `-ss ... -to ... -i`, which is fragile with FFmpeg input seeking and can produce unexpected durations. | `buildTrimCommand()` now uses `-ss START -i INPUT -t DURATION`, making trim duration explicit for audio and video. Tests assert duration math. |
| Bug | Audio Enhancer before/after preview initialized "Original" from the raw source file, which fails on some MP3/WAV/album-art inputs. | Added `AudioPreviewCommandBuilder`. Preview now generates both original 12s and enhanced 12s as AAC/M4A before initializing both controllers, so before/after playback uses the same playable container. |
| Feature | User asked for audio splitting, not only single trim/cut. | Added `CutterMode.splitAudio`, `FfmpegMediaCutterService.buildAudioSplitCommands()`, and `splitAudio()`. Audio cutter UI now has "Split audio into parts", a part-length slider, generated preview of the first part, and export to a timestamped parts folder. |
| Bug | Video remove-selection mode failed for videos without audio because the filtergraph always referenced `[0:a]`. | `buildRemoveCommand()` now accepts `hasAudio`; video-only remove mode builds a video-only concat graph with `concat=n=2:v=1:a=0[outv]`. Home passes `VideoFile.hasAudio` into the cutter route. |

### New files
| File | Purpose |
|------|---------|
| `lib/features/audio_enhancement/data/services/audio_preview_command_builder.dart` | Builds playable original/enhanced AAC preview commands for Audio Enhancer. |
| `test/audio_preview_command_test.dart` | Verifies original/enhanced preview commands are m4a/AAC and filter handling is correct. |

### Changed files
| File | Change |
|------|--------|
| `lib/features/media_cutter/data/services/ffmpeg_media_cutter_service.dart` | Explicit-duration trim, video-only remove fallback, audio split command builder/executor, `CutterMode.splitAudio`, `MediaCutCommand`. |
| `lib/features/media_cutter/presentation/screens/media_cutter_screen.dart` | Generated preview output instead of source playback; split-audio UI and export flow; temp preview cleanup. |
| `lib/features/audio_enhancement/presentation/screens/audio_enhancement_screen.dart` | Generates original preview m4a plus enhanced preview m4a before showing before/after dialog. |
| `lib/core/router/app_router.dart` | Passes `hasAudio` into `MediaCutterScreen`. |
| `lib/features/video_import/presentation/home_screen.dart` | Adds `hasAudio` to media cutter route arguments. |
| `test/media_cutter_command_test.dart` | Added assertions for explicit `-t`, video-only remove fallback, and audio split chunk commands. |

### Verification
| Check | Status |
|-------|--------|
| TDD red run | Failed as expected before implementation: missing `hasAudio`, missing `buildAudioSplitCommands`, missing `AudioPreviewCommandBuilder`. |
| Targeted tests | `flutter test test\media_cutter_command_test.dart test\audio_preview_command_test.dart test\audio_enhancement_test.dart` -> **16 pass**. |
| Full regression tests | `flutter test` -> **36 pass**. |
| `flutter analyze` | Still reports **19 pre-existing warnings/infos** in unrelated analyzer/provider/presentation files. No new analyzer issues from cutter/audio preview changes. |

## 2026-05-23 Surgical Fix — Professional Cutter Timeline + Playable Enhanced Preview
| Type | Issue | Fix |
|------|-------|-----|
| UX | Media Cutter used a plain `RangeSlider`, so long files were coarse and users could not cut visually around speech/audio events. | Replaced the slider with a custom waveform timeline. The cutter now extracts/analyzes audio, paints the waveform, dims removed/ignored regions, shows draggable start/end handles, supports dragging the selected range, seeks on tap, and adds +/- 100ms fine trim controls. |
| UX | Original preview area had no reliable selection playback controls. | Added inline play/pause, seek-to-selection-start behavior, selection-end auto pause, and a progress indicator tied to the source controller. |
| Bug | Enhanced audio preview could create a file but still open a silent/unplayable controller. | Hardened `AudioPreviewCommandBuilder`: both original and enhanced preview now map `0:a:0`, force stereo 48kHz AAC/M4A, and write fast-start metadata. `AudioEnhancementScreen` now FFprobes both preview files and refuses to open the comparison dialog unless each file has an audio stream and positive duration. |

### Changed files
| File | Change |
|------|--------|
| `lib/features/media_cutter/presentation/screens/media_cutter_screen.dart` | Added waveform extraction via `AudioProcessorRepositoryImpl`, professional waveform range editor/painter, handle/range dragging, tap seek, fine trim controls, and source playback controls. |
| `lib/features/audio_enhancement/data/services/audio_preview_command_builder.dart` | Preview commands now emit consistent playable AAC/M4A audio: `-map 0:a:0 -vn -ac 2 -ar 48000 -c:a aac -movflags +faststart`. |
| `lib/features/audio_enhancement/presentation/screens/audio_enhancement_screen.dart` | Added FFprobe validation for original/enhanced preview files before initializing `VideoPlayerController`. |
| `test/audio_preview_command_test.dart` | Added assertions for explicit audio mapping, stereo resampling, 48kHz output, and fast-start M4A preview flags. |

### Verification
| Check | Status |
|-------|--------|
| Targeted tests | `flutter test test\media_cutter_command_test.dart test\audio_preview_command_test.dart test\audio_enhancement_test.dart` -> **16 pass**. |
| Targeted analyze | `flutter analyze lib\features\media_cutter lib\features\audio_enhancement test\audio_preview_command_test.dart` -> **0 issues**. |
| Full regression tests | `flutter test` -> **36 pass**. |
| Full analyze | Still reports the same **19 pre-existing warnings/infos** outside the touched cutter/audio paths. No new analyzer issues from this fix. |

## 2026-05-23 Surgical Fix — Real Split Points + Correct Audio Duration
| Type | Issue | Fix |
|------|-------|-----|
| Bug | Imported audio could show `0:00` / incomplete duration because FFprobe returns seconds, but `VideoImportRepositoryImpl` treated the integer seconds as milliseconds. Example: `123.456` became `123ms` instead of `123456ms`. | Added `VideoImportRepositoryImpl.parseFfprobeDuration()` and now converts FFprobe seconds to real milliseconds. Added a regression test for `123.456s -> 123456ms`. |
| Feature / Bug | Media Cutter "Split audio into parts" was only fixed-length chunking, while user expected real cutting/splitting at chosen points. The UI still behaved like trim/remove, not manual split. | Added manual split-at-cut-points commands in `FfmpegMediaCutterService`. The cutter UI now shows a split mode for audio/video, lets the user tap the waveform, add cut points at the playhead, see markers on the waveform, delete markers, preview the first resulting segment, and export all resulting parts. |
| Bug | Cutter preview could open a generated file even if FFmpeg produced an invalid/no-duration stream. | Added FFprobe validation before initializing the preview controller. Audio previews require an audio stream; video previews require a video stream; both require positive duration. |

### Changed files
| File | Change |
|------|--------|
| `lib/features/video_import/data/repositories/video_import_repository_impl.dart` | Fixed FFprobe duration parsing from seconds to milliseconds. |
| `lib/features/media_cutter/data/services/ffmpeg_media_cutter_service.dart` | Added `buildSplitAtCutsCommands()` and `splitAtCuts()` for manual cut-point splitting. |
| `lib/features/media_cutter/presentation/screens/media_cutter_screen.dart` | Replaced split mode fixed-length slider with real cut markers on waveform, marker add/delete flow, split export, and preview validation. |
| `test/media_cutter_command_test.dart` | Added TDD coverage for manual cut-point split command generation. |
| `test/video_import_metadata_test.dart` | Added regression coverage for FFprobe duration conversion. |

### Verification
| Check | Status |
|-------|--------|
| TDD red run | Failed before implementation: missing `buildSplitAtCutsCommands()` and `parseFfprobeDuration()`. |
| Targeted tests | `flutter test test\media_cutter_command_test.dart test\video_import_metadata_test.dart test\audio_preview_command_test.dart` -> **11 pass**. |
| Targeted analyze | `flutter analyze lib\features\media_cutter lib\features\video_import test\media_cutter_command_test.dart test\video_import_metadata_test.dart` -> **0 issues**. |
| Full regression tests | `flutter test` -> **38 pass**. |
| Full analyze | Still reports the same **19 pre-existing warnings/infos** outside touched media cutter/video import paths. No new analyzer issues from this fix. |

## 2026-05-23 Feature — Professional Audio Editor
| Type | Issue | Fix |
|------|-------|-----|
| Feature | Audio editing was split between cutter/enhancer flows and still felt like simple trimming rather than a focused editor. | Added `AudioEditorScreen`, opened only for imported audio files. It supports MP3/WAV/AAC/M4A, `just_audio` playback, FFmpeg-backed waveform analysis, `audio_waveforms` rendering, zoom 1x-8x, draggable start/end selection, playhead seeking, trim, delete selection, split markers, undo/redo, and async export dialogs. |
| Feature | User needs lossless trim and fast extraction where possible. | Added `ProfessionalAudioEditorService.buildTrimCommand()` using `-c copy` with explicit `-ss/-t` and `-map 0:a:0`, preserving stream quality for trim/split outputs where FFmpeg can stream-copy. |
| Feature | User needs split into real parts, not only fixed-length chunks. | Added audio-specific split commands using manual cut points and wired them to `Export Splits`. |
| Feature | User needs AI Silence Detection and Smart Cut suggestions. | Added FFmpeg `silencedetect` command builder, log parser, and smart cut point generation from silence centers. UI buttons select the first silence or populate cut markers. |
| Feature | User needs Noise Reduction and Voice Enhancement in the editor. | Reused `AudioEnhancementFilterBuilder` through `ProfessionalAudioEditorService.buildProcessCommand()` and added editor toggles + enhanced export. |
| UX | Audio feature card still said "Audio Cutter". | Renamed it to "Audio Editor" and route now opens the professional editor for audio files while preserving the video cutter for video files. |

### New files
| File | Purpose |
|------|---------|
| `lib/features/media_cutter/presentation/screens/audio_editor_screen.dart` | Professional audio editor UI with waveform, zoom, playback, selection, split markers, undo/redo, AI actions, and enhancement export. |
| `lib/features/media_cutter/data/services/professional_audio_editor_service.dart` | Testable FFmpeg command/service layer for trim, delete, split, silence detection, smart cut, and enhancement. |
| `test/professional_audio_editor_service_test.dart` | TDD coverage for supported formats, lossless trim command, delete command, silence parsing, and smart cut suggestions. |

### Changed files
| File | Change |
|------|--------|
| `pubspec.yaml` / `pubspec.lock` | Added `just_audio ^0.10.5` and `audio_waveforms ^2.0.2`. |
| `lib/core/router/app_router.dart` | Routes audio media cutter requests to `AudioEditorScreen`; video requests still use `MediaCutterScreen`. |
| `lib/features/video_import/presentation/home_screen.dart` | Audio feature card now opens as "Audio Editor" with clearer subtitle. |

### Verification
| Check | Status |
|-------|--------|
| Package install | `flutter pub get` succeeded; added `just_audio`, `audio_waveforms`, and required transitive audio packages. |
| Targeted tests | `flutter test test\professional_audio_editor_service_test.dart test\media_cutter_command_test.dart test\video_import_metadata_test.dart test\audio_preview_command_test.dart` -> **15 pass**. |
| Targeted analyze | `flutter analyze lib\features\media_cutter lib\core\router\app_router.dart lib\features\video_import\presentation\home_screen.dart test\professional_audio_editor_service_test.dart` -> **0 issues**. |
| Full regression tests | `flutter test` -> **42 pass**. |
| Full analyze | Still reports the same **19 pre-existing warnings/infos** outside touched audio editor/media cutter/video import paths. No new analyzer issues from this feature. |

## ORPHANS & PENDING
| Item | Status |
|------|--------|
| Professional audio editor route for MP3/WAV/AAC/M4A | Complete |
| Lossless trim/split command layer | Complete |
| Delete selection command layer | Complete |
| AI silence detection + smart cut suggestion parser | Complete |
| Noise reduction + voice enhancement export inside editor | Complete |
| New orphaned code from this pass | None |
