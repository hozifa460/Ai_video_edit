# B1 — ملكية الملف وإبطال النتائج القديمة — OpenCode

- **التاريخ:** 2026-10-22
- **المنفّذ:** OpenCode
- **الحالة:** **منفذ — بانتظار مراجعة Codex.** لا يُعاد فتح SR-06/تصحيحات B01؛ judgment على B1 من Codex.
- **النطاق:** `docs/reviews/OPENCODE_BATCH_B1_REQUEST_AR.md` وحده: SR-04 وSR-07. حفظت خوارزميات الفترات والحدود والكشف والحماية؛ لم تُلمس VAD (SR-08) ولا SR-12/13/14/18 ولا cleanup/أداء/render accuracy.
- **المرجع:** `docs/reviews/CODEX_SR06_PRECISION_REVIEW_AR.md`.

---

## 1. ما نُفِّذ

### 1.1 هوية الجلسة (SR-04)

ملف جديد `lib/features/silence_detector/presentation/controllers/editor_detection_controller.dart` يعرّف `EditorDetectionController` (ChangeNotifier) يملك **كل** حالة محرر ملف واحد:

- `sessionId` يُولَّد عند الإنشاء ويُزداد على `close()`، فنتيجة A (جلسة قديمة) لا تُلتزم أبدًا في B.
- `detectionRequestId` يُولَّد لكل محاولة detection.
- `videoPath` ثابت للجلسة.
- `_audioPath`, `_timeline`, `_waveform`, `_params`, `_plan`، ونسخ params-version/plan-session/plan-request.

`EditorScreen` (في `_initVideo`) أنشأ متحكمًا لكل ملف وألغى الاشتراك في `dispose`. `_syncFromController` ينسخ حالة المتحكم إلى providers (mediaTimeline/silenceRemovalPlan/detectionParams) حتى تبقى widgets القديمة تعمل، لكن **المصدر único** للملكية والنسخ هو المتحكم.

### 1.2 إبطال بالنسخ (SR-04.2 / SR-07)

- `paramsVersion` (int) يُزاد على كل تغيير detection-relevant (threshold, min silence, guards, VAD, breathing). Smart Zoom **لا** يزيد `paramsVersion` (SR-07: zoom render-only).
- `renderRecipeVersion` يُزاد على كل تغيير Smart Zoom.
- `planIsValid` = plan != null && planSessionId == sessionId && planParamsVersion == paramsVersion && planRequestId != null.
- `planIsStale`، `canPreview`, `canProcess`, `needsRender`, `renderIsStale` مشتقة من هذه الأرقام.

تعديل any slider/toggle/Auto بعد كشف يرفع `paramsVersion` فيجعل الخطة **stale**: `canPreview`/`canProcess` يصبحان false، والواجهة تُظهر «Run silence detection first» عند Preview/Export.

### 1.3 حظر النتائج المتأخرة (SR-04.3)

`detect()` يلتقط `snapshotSessionId`, `snapshotParams`, `snapshotParamsVersion` قبل await، ثم عند الالتزام يتحقق من:
- `!_closed`
- `_sessionId == snapshotSessionId`
- `_detectionRequestId == requestId`
- `_paramsVersion == snapshotParamsVersion`

أي mismatch → النتيجة مُلغاة (لا commit). فشل detection لـB لا يُعيد A because A's plan was already cleared on `load()` (per-session state).

### 1.4 Keep this range (SR-04.3)

`keepInterval(index)` يعيد بناء الخطة **فقط** إذا `planIsValid`، ويبقي `paramsVersion`/`sessionId`/`requestId` (فقط removal set تغير). `SilenceTimeline` يمرّر controller ويستخدمه when valid، ويعود للـprovider fallback otherwise.

### 1.5 Render recipe (SR-07 / render)

- `markRendered(path)` يسجل `renderedRecipeVersion = renderRecipeVersion`.
- `renderIsStale` = rendered != null && renderedRecipeVersion != renderRecipeVersion.
- `needsRender` = planIsValid && (no output || renderIsStale).
- changing Smart Zoom bumps renderRecipeVersion only → render stale، detection untouched.
- `setWaveformZoom` لا يلمس أي version (display-only).

### 1.6 واجهات services (host-testable)

`lib/features/silence_detector/domain/services/editor_services.dart` يعرّف `MediaProbeService`, `AudioExtractionService`, `SilenceDetectionService`, `ProcessingService`. المتحكم يقبلها (مع defaults من repositories). `_syncFromController` etc.

### 1.7 Auto threshold

`autoDetectThreshold()` يشغّل `AdaptiveThresholdService` ويستدعي `setParams` (يرفع paramsVersion → خطة stale) — consistent with SR-07.

## 2. ما لم يتغيّر

- خوارزميات الفترات (normalize/union/complement/padding/breathing) — untouched.
- SR-06 (threshold passes, trailing, numeric margin) — untouched.
- VAD (SR-08) — untouched.
- SR-12/13/14/18 — not declared closed.
- cleanup/أداء/render accuracy — untouched.
- threshold/VAD/FFmpeg/stream selection policies — untouched.

## 3. الاختبارات

- `test/editor_detection_controller_test.dart` = **9 ناجحة**: عزل جلستين، إلغاء نتيجة متأخرة عند close، إلغاء عند تغيير params، ترتيب إكمال معكوس (فقط الأحدث)، planIsStale/canPreview، Smart Zoom يبطل render فقط، waveform zoom لا يبطل detection/render، keepInterval يعيد بناء الخطة، keepInterval no-op عند staleness.
- full suite: **317 ناجحًا** (308 + 9)، analyze نظيف.

## 4. حدود التحقق

- لا جهاز، لا Android/iOS، لا build، لا FFmpeg حقيقي، لا وسائط.
- `_initVideo` (probe/extract/waveform) ما زال يُنفَّذ في الشاشة ويستدعي `_controller.load(...)` afterwards; هوية/invalidation مختبرة على controller، والربط بالشاشة موجود لكن لم يُضخ (`EditorScreen` يحتاج VideoPlayerPlatform).
- `ProcessingService` default يُعيد خطأ «wired by the screen» — render الفعلي remains in `_previewResult`/`_processAndExport` (Smart Zoom still passed to `startProcessing`).
- `autoDetectThreshold` يغير params → plan stale، متسقًا مع SR-07 (Auto no longer silently leaves old plan).

## 5. الخطوة التالية

Codex يقرأ PROJECT_MEMORY من القرص ويراجع `OPENCODE_BATCH_B1_RESULT_AR.md` والمصدر و`editor_detection_controller_test.dart`، ثم يسجّل حكمه ويحدّث الذاكرة. **لا دفعة B2 قبل ذلك.** SR-12/13/14/18 remain open.