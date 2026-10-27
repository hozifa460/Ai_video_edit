# B1 — تصحيحات قبل B2 — OpenCode

- **التاريخ:** 2026-10-22
- **المنفّذ:** OpenCode
- **الحالة:** **منفذ — بانتظار مراجعة Codex.** SR-04/SR-07 أعيدتا للتصحيح (B1-R1..R5)؛ judgment من Codex.
- **النطاق:** `docs/reviews/OPENCODE_BATCH_B1_REVISION_REQUEST_AR.md` وحده. حفظت خوارزميات الفترات والحدود والكشف والحماية؛ لم تُلمس VAD (SR-08) ولا SR-12/13/14/18 ولا cleanup/أداء/render accuracy ولا سياسات threshold/VAD/FFmpeg/stream selection.
- **المرجع:** `docs/reviews/CODEX_BATCH_B1_REVIEW_AR.md`.

---

## 1. ما نُفِّذ

### B1-R1 — ناتج المعالجة مرتبط بالهوية

- `markRendered(String outputPath)` صار **يتحقق** من `_closed` و`planIsValid` قبل التسجيل؛ ناتج متأخر بعد close или بعد stale plan لا يُسجَّل. `renderedOutputPath`/`renderedRecipeVersion` يُمسحان عند `close()`.
- `keepInterval` يُبطل الناتج (مسح renderedOutputPath/renderedRecipeVersion) because the removal set changed.
- `detect()` success يُبطل الناتج (خطة جديدة).
- `needsRender` = planIsValid && (no output || renderIsStale). `renderIsStale` = rendered != null && renderedRecipeVersion != renderRecipeVersion.
- `_previewResult`/`_processAndExport` في الشاشة يتحققان من `controller.canPreview`/`canProcess` **قبل** البدء، ويستدعيان `markRendered(outputPath)` عند اكتمال المعالجة. `_processAndExport` يمرر `smartZoom: params.smartZoom` (recipe) — zoom-only لا يُعيد كشف الصوت.
- `ProcessingService` (محقون) remains the seam; default returns "wired by the screen".

### B1-R2 — الطلب المهمل ينتهي نظيفًا

- `detect()` عند mismatch في `paramsVersion` (أو closed/session/request) يضبط `_status = idle` و`notifyListeners()` (بدلاً من return صامت). `isDetecting` becomes false؛ `canPreview` stays false because plan is stale.
- `autoDetectThreshold` (R3) also restores status on discard.

### B1-R3 — Auto قابلة للحقن ومحروسة

- `EditorDetectionController` accepts `AdaptiveThresholdService? autoThresholdService` (default `AdaptiveThresholdService()`). `_autoThresholdService` field.
- `autoDetectThreshold()` captures `snapshotSessionId`, `snapshotParams`, `snapshotParamsVersion`, `_autoRequestId`; checks `_closed`/session/request/version on commit; returns without notify if stale. If nothing changed (file missing → returns currentParams), preserves `_status` (ready stays ready) so `canPreview` remains true. If changed, `setParams` (bumps version → stale) and status idle.
- Does not notify after dispose.

### B1-R4 — fallback removed; load unified

- `SilenceTimeline` onPressed: if controller != null → `controller.keepInterval(index)` (no fallback to global provider even when stale → no-op). Only falls back to provider when controller is null.
- `load({audioPath, timeline?})`: if timeline provided, uses it (no second probe); else probes. Screen passes `resolvedTimeline` → unified ownership, no intermediate duration published. `_closed` checked after probe.
- Isolation tested: A with real plan then B (shorter, fails) leaves global plan untouched when B's controller is used; keep during stale/detecting is no-op.

### B1-R5 — SilenceDetectionGate في مسار controller.detect

- `_detectBlockedReason()` (custom strings) removed. `detect()` uses `SilenceDetectionGate.blockerFor(_timeline)` and `messageFor(...)` for `detectionError`. Contract F2 (shared message) preserved through the new path. `EditorScreen.detectionBlockedMessage` static kept for legacy tests but screen's detect path now goes through controller.

## 2. ما لم يتغيّر

- خوارزميات الفترات/الحدود/SR-06/VAD (SR-08)/render accuracy/cleanup/ native cancellation.
- SR-12/13/14/18 not declared closed.

## 3. الاختبارات

- `codex_batch_b1_acceptance_test.dart` = **10/10 ناجحة** (كانت 1/10).
- `test/editor_detection_controller_test.dart` = 9 ناجحة (ما زالت).
- full suite: **317 ناجحًا**، analyze نظيف.

## 4. حدود التحقق

- لا جهاز/Android/iOS/build/FFmpeg/وسائط.
- `EditorScreen` لم يُضخ (VideoPlayerPlatform).
- Render الفعلي still in `_previewResult`/`_processAndExport` (Smart Zoom passed to startProcessing).

## 5. الخطوة التالية

Codex يقرأ PROJECT_MEMORY من القرص ويراجع `OPENCODE_BATCH_B1_REVISION_RESULT_AR.md` والمصدر و`codex_batch_b1_acceptance_test.dart` (10/10)، ثم يسجّل حكمه ويحدّث الذاكرة. **لا B2 قبل ذلك.**