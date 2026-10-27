# تقرير تنفيذ الدفعة الأولى — إزالة السكتات (OpenCode)

- **التاريخ:** 2026-10-05
- **المنفّذ:** OpenCode (مسؤول التنفيذ)
- **الحالة:** **منفذة — بانتظار مراجعة Codex المستقلة. ليست معتمدة نهائيًا.**
- **النطاق:** SR-01، SR-02، SR-03، SR-05، SR-19 فقط (سلامة الفترات والمدة).
- **خارج النطاق ولم يُلمس:** الدفعة B (SR-04/07/12/13/14/18)، C (SR-06/08/09/24)، D (SR-10/11/20/21/22/23)، E (SR-15/16/17 + R-01..R-10).
- **مراجعته:** راجع الحالة قبل التعديل بقراءة `AGENTS.md` و`PROJECT_MEMORY.md` و`docs/reviews/SILENCE_REMOVAL_REVIEW_AR.md` و`docs/reviews/OPENCODE_HANDOFF_AR.md` من القرص.

---

## 1. التحقق من وجود كل عيب في الكود الحالي قبل إصلاحه

كل بند من الخمسة ثبتُّه في المصدر قبل التعديل، وليس من نص التقرير فقط:

| SR | الفحص | النتيجة قبل الإصلاح |
|---|---|---|
| SR-01 | `silence_detector_repository_impl.dart` سطر `mergeCloseSegments(segments, params.minSilenceDuration)` | **مؤكد**: `minSilenceDuration` كان يُستخدم كحد gap؛ فجوة 0.2s عند min=0.25 ⇒ `[1,2] + [2.2,3]` تصبح `[1,3]`. وكذلك `ffmpeg_silence_datasource.dart` `_mergeResults` كان يملأ فجوات حتى 0.15s. |
| SR-02 | `silence_detector_repository_impl.dart` `applyPadding` | **مؤكد**: `start - paddingBefore` و`end + paddingAfter` ⇒ `[1,2]` مع 0.15/0.15 تصبح `[0.85,2.15]`، أي حذف 150ms من كلام على كل جانب. |
| SR-03 | `totalSilenceDurationProvider` كان `fold` على القائمة الخام، و`ffmpeg_cutting_service.dart` `_buildSpeechSegments` كان يبني المتممة من ترتيب المدخلات | **مؤكَّد**: لا normalization نهائي، ولا `union` عند القياس. |
| SR-05 | `editor_screen.dart` كان يقرأ `_waveform?.durationSeconds ?? 0` ويستخدمه للمدة؛ `applyPadding` كان يطبّق clamp على كل شيء إلى `[0, totalDuration]` | **مؤكَّد**: فشل waveform ⇒ duration 0 ⇒ `applyPadding` تُسقط كل الفترات. ولا يوجد أي `start_time` صوتي ولا تعويض على خط زمني الفيديو. |
| SR-19 | `silence_detector_repository_impl.dart` `mergeCloseSegments` كان يستخدم `segment.endSeconds` مباشرة بلا `max` | **مؤكَّد**: `[1,5]` ثم `[2,3]` ⇒ `[1,3]`. |

`flutter analyze --no-pub` قبل التعديل: **No issues found**. `flutter test --no-pub`: **81 ناجحًا**. `docs/reviews/repro/silence_characterization_test.dart`: **7 ناجحة** — كل الأمثلة السبعة كانت تمر بمثلث السلوك المعيب.

---

## 2. المشاكل المعالجة والأسباب الجذرية

### SR-01 — P1 — دمج السكتات يحذف الكلام الواقع بينها

**السبب الجذري:** `minSilenceDuration` كان مُعامل دمج. هو عتبة « Detecting»، لكنها استُخدمت أيضًا كسياسة دمج، فأي فاصل أقصر منها أصبح حذفًا. الصوتExcerpt short is common.

**الإصلاح:**
- `SilenceDetectorRepositoryImpl.buildRemovalPlan` يستدعي `IntervalAlgebra.normalize(..., gapToleranceSeconds: 0)` بعد كل مرحلة. **لا existe أي مسار دمج مبني على `minSilenceDuration` بعد الآن.**
- `_mergeResults` في `ffmpeg_silence_datasource.dart` لم يعد يملأ فجوات 0.15s؛ صار `union` بسماحية حدودية واحدة مقدارها `kPassBoundaryToleranceSeconds = 0.02` (20ms = إطار VAD واحد) لامتصاص اهتزاز حدود العيّنات بين تمريرَي `silencedetect` فقط. هذه موثّقة كسماحية عيّنات وليست سياسة حذف كلام.
- فُصل معنى «الصمت المؤكد» عن معنى «الكلام قصير»: مدة الكلام لم تعد تُستخدم كسبب للدمج في أي مكان.

**مثال قبل/بعد** (`[1,2]` و`[2.2,3]`، مدة 10s، guards صفر، timeline 10s):

| | removals | kept | removedSeconds |
|---|---|---|---|
| قبل | `[1,3]` | `[0,1]`, `[3,10]` | 2.0 (شاملة 0.2s من الكلام) |
| بعد | `[1,2]`, `[2.2,3]` | `[0,1]`, `[2,2.2]`, `[3,10]` | 1.8 |

وعند `minSilenceDuration = 5.0` النتيجة **بعد** لا تزال `1.8` — لا يتغير شيء مع رفع الحد.

### SR-02 — P1 — الـpadding كان يوسّع الحذف إلى الكلام

**السبب الجذري:** دلالتان متعارضتان لكلمة padding: «الحد الآمن» و«اترك هامشًا قبل كلمة/بعدها». التنفيذ كان التوسعة، والواجهة كانت تعرضها كـ«Padding».

**الإصلاح — عقد واضح:** `paddingBefore`/`paddingAfter` صارا **مساحة محمية داخل حدود السكتة المؤكدة**: كل فاصل حذف يصبح `[start + before, end − after]`، مع clamp داخل `[0, totalDuration]`، ويُحذف كليًا إذا تبتلعه الحارسان. لا يوجد أي مسار يوسّع الحذف خارج الصمت المؤكد. الواجهة سُمّيت **«Speech Guard Before/After»** مع سطر شرح صريح، وأيقونة القائمة أصبحت tooltip: «Keep this range in the output (exclude from removal)».

**مثال قبل/بعد** (`[1,2]`، duration 10، guards 0.15/0.15):

| | removal | deleted inside silence | deleted outside |
|---|---|---:|---:|
| قبل | `[0.85, 2.15]` | 1.0s | **0.3s من كلام** |
| بعد | `[1.15, 1.85]` | 0.7s | 0 |

سلسلة الحارس (0 / 50 / 150 / 500ms) تعطي حذفًا متناقصًا: `1.0 → 0.9 → 0.7 → 0.0` ثانية.

### SR-03 — P2 — التداخل بعد padding يفسد الإحصاءات وعقد القص

**السبب الجذري:** ثلاث نسخ مستقلة من «ما الذي يُحذف»: قائمة الـdatasource، القائمة بعد الدمج، والقائمة بعد padding. الإحصاء يجمع الخام، و`_buildSpeechSegments` يبني المتممة من ترتيب المدخلات، فلا يضمن أحد تطابقها.

**الإصلاح:** كائن واحد `SilenceRemovalPlan` هو المصدر الوحيد:
- `SilenceRemovalPlan.build` يطبّع `removals` (finite → clamp → sort → union بـ`max(end)`)، ثم يشتق `kept` كـ`complement` على `[0, totalDurationSeconds]`.
- ضمانات صريحة: `removedSeconds + keptSeconds == totalDurationSeconds`، و`0 ≤ removed ≤ total`، و`removedRatio ∈ [0,1]` و`0` عند timeline صفري.
- `totalSilenceDurationProvider` و`SilenceTimeline` و`editor_screen` (نسبة الحذف) و`preview_screen` (removedDuration/originalDuration) تأخذ كلها من الخطة نفسها. `IntervalAlgebra.totalSeconds` يقيس **الاتحاد** دائمًا حتى لو مرّ متصل فاسد غير مطبَّع.
- `FfmpegCuttingService._buildSpeechSegments` **حُذفت**؛ `cutWithConcat` يقرأ `plan.kept` مباشرة، فالمouge والصورة يُقصّان على نفس الفترات بالبناء.
- استبعاد عنصر من قائمة السكتات يعيد بناء الخطة كاملة (`plan.withoutRemoval(index)`)، فلا يبقى مجموع قديم.

**مثال قبل/بعد** (`[1,2]` و`[2.6,3.5]`، guards 0.5/0.5، duration 10):

| | الواجهة كانت تعرض | Complement القديم | removed + kept |
|---|---|---|---|
| قبل | `3.9s` (مجموع `[0.5,2.5]`+`[2.1,4]`) | `10.4s` ⇒ duration معالجة سالبة | **13.3 ≠ 10** |
| بعد | `1.9s` (الاتحاد، فاصلتان غير متداخلتين) | `8.1s` | **10.0 = total** |

### SR-05 — P1 — المدة المرجعية كانت مرتبطة بالـwaveform بدل الفيديو

**السبب الجذري:** المدة كانت تُشتق من `analyzeWaveform` (bytes ÷ sampleRate). فشل التحليل ⇒ 0، ثم `applyPadding` كانت تحذف كل الفترات عند clamp على 0. ولا يوجد أي offset من `start_time` الصوتي إلى خط زمني الفيديو.

**الإصلاح:**
- `MediaProbeDatasource` جديد: FFprobe مرة واحدة، يقرأ مدة الفيديو (تفضّل `duration` مسار الفيديو على مدة الحاوية لأن الأخيرة قد تحوي ذيل صوتي بلا صورة)، و`start_time` الصوت، ومدة الصوت، ووجود مسار صوتي. القيم غير القابلة للقراءة (`N/A`, NaN) تنهار إلى 0، وغياب المدة يُرجع خطأ صريحًا لا «مدة صفر ناجحة».
- `MediaTimeline` كيان جديد يحمل `videoDurationSeconds`, `audioStartSeconds`, `audioDurationSeconds`, `hasAudio`، مع `detectionWindowEndSeconds` و`audioToVideoTimeline()`. كل قيمة غير سالبة أو غير محدودة تُقصّ إلى 0.
- ترتيب خط زمني الفيديو صار: probe قبل أي قياس ⇒ استخراج الصوت (يُثبت وجود الصوت) ⇒ waveform للعرض فقط ⇒ كشف على نافذة الصوت ⇒ **نقل النتيجة إلى خط زمني الفيديو** ⇒ بناء الخطة على مدة الفيديو ⇒ complement يغطي مدة الفيديو كاملة.
- fallback إذا فشل الـprobe هو **مدة `VideoPlayerController`** (مدة فيديو حقيقية)، وليس الـwaveform. فشل الـwaveform صار أخيرًا في السجل فقط.
- واجهة الرسم (waveform/timeline) تستخدم `timeline.videoDurationSeconds` كمسطرة.

**أمثلة قبل/بعد:**

| الحالة | قبل | بعد |
|---|---|---|
| فيديو 10s، صوت 8s، silence `[1,2]` | `totalDuration=8` من الـwaveform؛ ذيل 8→10s قد يمحوه clamp | `totalDuration=10`؛ `kept = [0,1] + [2,10]` ⇒ ذيل الصورة يبقى |
| audio `start_time=0.5`، duration 9، فيديو 10s | لا يوجد أي تعويض؛ قرار الصمت على المحور الصوتي والقص على محور الفيديو | detection على نافذة `[0,9]`، ثم `audioToVideoTimeline` يزيح `+0.5`؛ `[1,2] → [1.5,2.5]`؛ removals لا تتجاوز 10 |
| فشل waveform | `duration=0` ⇒ كل الفترات تُحذف | المدة من probe = 10؛ الخطة تُبنى بشكل صحيح؛ waveform يبقى `null` ولا يدخل أي حساب |

### SR-19 — P2 — `mergeCloseSegments` يصغّر interval عند الاحتواء

**السبب الجذري:** `endSeconds` للمدخل الجديد كان يُسند مباشرة بلا `max`، فلو احتوى الفاصل الثاني الأول تناقصت النهاية.

**الإصلاح:** `IntervalAlgebra.union` هو التنفيذ الوحيد: ترتيب بـ`start` (وعند التساوي الأطول أولًا)، ثم `end = max(lastEnd, currentEnd)`. طُبِّق على `overlap`/`nested`/`equal`/`unsorted`. لم تعد هناك دالة دمج ثانية.

---

## 3. الملفات المعدلة

### جديدة — `lib/features/silence_detector/` (7)

| الملف | الدور |
|---|---|
| `domain/services/interval_algebra.dart` | جبر الفترات الخالص: `normalize`, `union`, `complement`, `totalSeconds`, `applyProtectedPadding`, `finiteOr`, `nonNegativeOrZero` + `kMinSilenceIntervalSeconds` |
| `domain/entities/silence_removal_plan.dart` | الخطة canonical: `removals` + `kept` + إحصاءات/مدد/نسب + `withoutRemoval` |
| `domain/entities/media_timeline.dart` | الخط الزمني المجرَّب: مدة الفيديو، إزاحة الصوت، نافذة الكشف، `audioToVideoTimeline`, `videoToAudioTimeline`, `isDetectable` |
| `data/datasources/media_probe_datasource.dart` | FFprobe لمرة واحدة + `parseSeconds` قابل للاختبار |

### معدَّلة — `lib/features/silence_detector/` (6)

| الملف | التغيير |
|---|---|
| `domain/entities/silence_segment.dart` | `isFiniteBounds`, `isValid`, `contains`, `overlaps` — حدود الصنف صارت قابلة للتحقق |
| `domain/repositories/silence_detector_repository.dart` | العقد صار `buildRemovalPlan({audioPath, params, timeline}) → Result<SilenceRemovalPlan>`؛ حُذفت `mergeCloseSegments`/`applyPadding` |
| `data/repositories/silence_detector_repository_impl.dart` | إعادة كتابة: ترتيب normalize → VAD → guards → breathing → normalize → audio→video → plan؛ حقن datasource/VAD/breathing؛ رفض timeline غير قابل للاستخدام بخطأ مصنّف |
| `data/datasources/ffmpeg_silence_datasource.dart` | `_mergeResults` صار union بسماحية 20ms؛ `_parseSilenceOutput` يرفض الأزواج غير finite/المقلوبة؛ `kPassBoundaryToleranceSeconds` |
| `data/services/breathing_protection_service.dart` | صارت تأخذ قائمة واحدة وتُخرج `union` مطبَّعة؛ لا تدمج ولا تنمو |
| `domain/providers/silence_detection_provider.dart` | `silenceRemovalPlanProvider` (مصدر الحقيقة)، `mediaTimelineProvider`، `silenceSegmentsProvider` صار Provider مشتقًا للقراءة فقط، `totalSilenceDurationProvider` يقرأ من الخطة، `keepInterval(i)` يعيد بناء الخطة |

### معدَّلة — الطبقات الأعلى (5)

| الملف | التغيير |
|---|---|
| `video_processing/domain/repositories/video_processor_repository.dart` | `processVideo({videoPath, audioPath, plan, quality, ...})` بدل `silenceSegments + totalDuration` |
| `video_processing/data/repositories/video_processor_repository_impl.dart` | يمرّر الخطة؛ يفحص `plan.isUsable` قبل أي FFmpeg |
| `video_processing/domain/providers/processing_provider.dart` | `startProcessing` يمرّر الخطة |
| `video_processing/data/services/ffmpeg_cutting_service.dart` | **حُذفت** `_buildSpeechSegments`؛ `cutWithConcat` يقرأ `plan.kept`؛ `outputDurationMs = plan.keptDuration.inMilliseconds` |
| `silence_detector/presentation/editor_screen.dart` | probe قبل القياس؛ المدة من `mediaTimelineProvider`؛ `buildRemovalPlan`؛ Preview/Export يمرّران الخطة ويقرآن `plan.removedDuration`/`plan.totalDuration`؛ `_requireRemovablePlan` يحجبggy الفراغات؛ fallback = مدة player |

### معدَّلة — العرض (2)

| الملف | التغيير |
|---|---|
| `presentation/widgets/silence_timeline.dart` | النسبة من `plan.removedPercent`؛ الاستبعاد عبر `keepInterval`؛ tooltip معنى واضح |
| `presentation/widgets/detection_settings_panel.dart` | «Padding» ⇒ «Speech Guard» + شرح دلالات الحارس |

### اختبارات جديدة (3) + معدَّل (1)

- `test/silence_interval_algebra_test.dart` — **25 اختبارًا** (SR-01/02/03/19 خالصة)
- `test/silence_removal_plan_test.dart` — **17 اختبارًا** (ثوابت الخطة + `MediaTimeline`/SR-05)
- `test/silence_detection_pipeline_test.dart` — **12 اختبارًا** (خط أنابيب كامل مع fakes للـplugin)
- `docs/reviews/repro/silence_characterization_test.dart` — **معدَّل**: لم يبقَ إلا SR-08 وSR-12 (مفتوحتان)، مع رأس يربط كل SR مُحوَّل بمكان اختباره

### توثيق أُعيد توليده

- `docs/SOURCE_INVENTORY.md` عبر `python tools/review_inventory.py` (145 ملف Dart، 24,291 سطرًا). **`docs/reviews/REVIEW_BASELINE.json` لم يُمس.**

---

## 4. الاختبارات والنتائج الفعلية

### الأوامر التي شُغِّلت ونتائجها الحرفية

| الأمر | النتيجة الفعلية |
|---|---|
| `flutter analyze --no-pub` (قبل التعديل) | `No issues found! (ran in 5.3s)` |
| `flutter test --no-pub` (قبل التعديل) | `00:04 +81: All tests passed!` |
| `flutter test --no-pub docs/reviews/repro/silence_characterization_test.dart` (قبل) | `00:00 +7: All tests passed!` |
| `flutter analyze --no-pub` (بعد التعديل) | `No issues found! (ran in 4.9s)` / `(ran in 5.1s)` بعد `dart format` |
| `flutter test --no-pub` (بعد التعديل) | **`00:08 +135: All tests passed!`** (81 سابقة + 54 جديدة) |
| `flutter test --no-pub test/silence_interval_algebra_test.dart` | `00:00 +25: All tests passed!` |
| `flutter test --no-pub test/silence_removal_plan_test.dart` | `00:00 +17: All tests passed!` |
| `flutter test --no-pub test/silence_detection_pipeline_test.dart` | `00:00 +12: All tests passed!` |
| `flutter test --no-pub docs/reviews/repro/silence_characterization_test.dart` (بعد) | `00:00 +2: All tests passed!` (SR-08، SR-12) |
| `dart format` على 13 ملفًا جديد/مُعاد كتابته | `Formatted 13 files (13 changed)`، ثم أُعيد التحليل والاختبارات فكلها خضراء |

### إثبات «يفشل قبل الإصلاح / ينجح بعده»

أمثلة `docs/reviews/repro/` القديمة كانت **تنجح** بالعكس (تؤكد السلوك المعيب)، وهو ما يجعلها دليلًا غير كافٍ بمفردها. لذلك أنشأت ملف evidence مؤقتًا يضع **نسخ دوال ما قبل الإصلاح حرفيًا** (من baseline 2026-10-05: `mergeCloseSegments`, `applyPadding`, و`_buildSpeechSegments`) ويؤكد عليها **الـinvariants الجديدة نفسها**. شُغّل ثم حُذف:

```
flutter test --no-pub docs/reviews/repro/opencode_batch01_before_fix_evidence_test.dart --reporter expanded
→ 00:00 +0 -8: Some tests failed.
```

**الـ8 invariants تفشل كلها على كود ما قبل الإصلاح:**

| الـinvariant | المتوقع | الفعلي على الكود القديم |
|---|---|---|
| SR-01: جزيرة 200ms تبقى | `[1,2]`,`[2.2,3]` | `[1,3]` |
| SR-01: min=5s لا يوسّع الحذف | نفس النتيجة عند 0.25 و5.0 | فاصل 500ms اندمج عند 5.0 ⇒ `[1,3]` |
| SR-02: الحارس يُبقي الحذف داخل السكتة | `start ≥ 1` | `0.85` |
| SR-02: رفع الحارس يقلّل الحذف | `0.15 < 0.05` في الاتجاه المطلوب | `1.3 > 1.1` |
| SR-03: القياس = الاتحاد | `3.5` | `3.9` |
| SR-03: removed + kept = total | `10` | `10.4` |
| SR-05: duration صفر لا تحذف الكل | غير فارغ | `[]` |
| SR-19: الاحتواء يبقي النهاية الخارجية | `5` | `3` |

الـinvariants نفسها (بصيغ أنظف وشاملة) صارت الآن في `test/` ضمن الـ135 ناجحًا. حُذف ملف evidence بعد التقاط المخرجات حتى لا يبقى ملف فاشل دائمًا في المشروع؛ السجل النصي أعلاه هو الدليل.

### تغطية fixtures القبول من ملف التسليم

| Fixture المطلوب | مكان التغطية | الحالة |
|---|---|---|
| صمت `[1,2]` و`[2.2,3]` — الاحتفاظ بـ200ms حتى عند رفع min silence | `silence_detection_pipeline_test.dart` «200ms island survives…» (يختبر 0.01/0.25/2.0/5.0) | ✅ |
| padding 0/50/150/500ms — لا يزداد الكلام المحذوف | `silence_detection_pipeline_test.dart` «0 / 50 / 150 / 500ms guards» + `silence_interval_algebra_test.dart` | ✅ |
| overlap/nesting/unsorted/NaN/Infinity — رفض أو normalize حتمي | `silence_interval_algebra_test.dart` (مجموعتا SR-19 وSR-03) + `silence_removal_plan_test.dart` | ✅ |
| فيديو 10s وصوت 8s — لا يُقص ذيل الصورة | `silence_removal_plan_test.dart` «video longer than audio keeps the picture tail» + `…detections beyond the audio window…» | ✅ |
| audio start offset +500ms | `silence_removal_plan_test.dart` («audio offset moves…», «detection cannot reach past the video…») + `silence_detection_pipeline_test.dart` | ✅ |
| فشل waveform — لا تتحول metadata الصحيحة إلى مدة 0 | `silence_removal_plan_test.dart` «a failed waveform cannot become the timeline» + منطق probe في `editor_screen` | ⚠️ جزئي: الاختبار يثبت أن الخطة لا تعتمد مدخل الـwaveform، لكن **مسار `MediaProbeDatasource` نفسه غير مُختبَر على جهاز** (انظر القيود) |
| min=2s وسكتة 0.4s — كل الـpasses تحترم العقد | — | ❌ **SR-06، خارج هذه الدفعة** (انظر المتبقي) |

---

## 5. القيود — ما لم يُشغَّل إطلاقًا

لم أُنفّذ ولا أزعم ما يلي:

- **لا build لـAndroid ولا لـiOS.** لم يُشغّل `flutter build apk/ipa` ولا أي عملية بناء.
- **لا تشغيل للتطبيق على أي جهاز/محاكي.** لم تُفتح `EditorScreen` فعليًا، ولم تظهر رسالة، ولم يُجرَّب slider، ولم يُضغط زر Preview/Export.
- **لا تنفيذ لـFFmpeg إطلاقًا.** لا `silencedetect`، لا extract، لا encode، لا concat، لا probe فعلي على ملف. كل ما يخص FFmpeg هو بناء أوامر ونصوص منطق خالصة.
- **لا ملف وسائط حقيقي عولج**، ولا_probe على وسائط المستخدم، ولا قياس جودة صوت، ولا فحص A/V sync، ولا قياس دقة نقطة القطع، ولا اختبار خارج keyframes أو VFR أو portrait/SAR.
- **لم يُبنَ native binary** لـffmpeg_kit_flutter_new، لذا `MediaProbeDatasource.parseSeconds` مُختبَّر كدالة نقية فقط، لا كـprobe على ملف.
- **لا قياس RAM/سرعة UI**.
- **لا مقارنة Git diff**: لا يوجد `.git` في هذه النسخة، فلا مقارنة commits متاحة. بصمات baseline في `docs/reviews/REVIEW_BASELINE.json` لم تُحدَّث.

**النتيجة:** كل ما سبق **حسابات ووحدات ومنطق خالص على host Dart**. هذا يثبت أن العقد الرياضي صار صحيحًا، ولا يثبت أن FFmpeg ينفّذه على وسائط حقيقية، ولا أن speech guard لا يقطع حرفًا عربيًا في encoder معين.

---

## 6. المشاكل المتبقية والقيود الجديدة

### متبقية داخل نطاق الدفعة

| ID | لماذا لم تُعالَج | الأثر المتبقي |
|---|---|---|
| **SR-06** | مُسندة للدفعة C صراحةً، ولم أغيّرها | **الأخطر المتبقي وقريب من SR-01**: `FfmpegSilenceDatasource` ما زال يمرّر `minSilenceDuration: 0.3` ثابتة في التمريرة الثانية عند threshold−10dB. عند `minSilenceDuration=2s` تُقبل سكتات 0.4s من التمريرة الثانية وتُحذف. **تنقص الآن** لأن الدمج لم يعد يبتلعها مع جيران، لكنها ما زالت تُحذف. هذه مخاطرة فقدان كلام حقيقية لم تُغلق. |
| **SR-04** | الدفعة B | `silenceRemovalPlanProvider` ما زال عامًّا بلا هوية ملف. بعد نجاح كشف على ملف A، فتح B يبدأ قبل كشفه قد يعرض خطة A ويصدر بها. **لم worsens** (سلوك مطابق لما قبله) لكنه لم يُحل. |
| **SR-21** | الدفعة D | أضفت `_requireRemovablePlan` في `editor_screen` كحاجز بدل encode فارغ: تصفر في `kept.isEmpty` و`!hasRemovals` و`!isUsable` وتعرض رسالة. هذه **حالة خطأ نصية وليست نتيجة typed** كما يطلب SR-21؛ `FfmpegCuttingService` ما زال يعيد `null` وrepository يحوّله إلى `'FFmpeg processing returned no output'`. |
| **SR-07** | الدilege B | تعديل guards/threshold لا يُبطل الخطة القديمة ولا يلمس `plan`؛ ما زال يمكن تصدير نتائج بإعدادات أقدم. |
| **SR-10/11/22/23** | الدفعة D | القص ذو الجزء الواحد ما زال `-ss/-t -c:v copy`؛ `exportVideo` ما زال يحسب `videoDurationMs = double.tryParse(durationStr)?.round()` بالثواني؛ audio stream غير مُختار صراحة. |

### قيود جديدة أُدخلت بها

1. **`kPassBoundaryToleranceSeconds = 0.02`**: توحيد لاهتزاز حدود العيّنات بين تمريرَي `silencedetect`. موثّق وموصول في `interval_algebra_test.dart`. **مراجعته مطلوب**: إذا رأى Codex أن 20ms كافية لابتلاع كلمة، يجب خفضها.
2. ** preferring مدة مسار الفيديو على مدة الحاوية**: `MediaProbeDatasource` يختار `videoStream.duration` ويستخدم `mediaInfo.duration` كبديل. هذا قرار تحسّن (يمنع ذيل صوتي بلا صورة من تضخيم الخط الزمني) لكنه **غير مُختبَر على وسائط متعددة المسارات**.
3. **حارس `kMinSilenceIntervalSeconds = 1ms`**: أي فاصل أقصر يُحذف. معيار متناسق لكنه اختيار.
4. **VAD ما زال يعمل على الخط الزمني الصوتي** ثم نزيح. `_NoopVadService` في الاختبار لا يُثبت سلوك VAD الحقيقي على وسائط.
5. **`_playerDurationSeconds()` fallback**: إذا فشل الـprobe يُستخدم `VideoPlayerController.value.duration`. هذا أفضل من الـwaveform لكنه ليس مدة مجرَّبة، ولم يُختبر سلوكه على ملفات يختلف فيها المشغّل عن الحاوية.
6. **`removedSeconds` يُقاس بالاتحاد على ثوانٍ `double`**: تجميع آلاف الفترات قد يجمع خطأ عائمًا ضئيلًا؛ ثابت `removed + kept == total` مُختبر ضمن `1e-9` على fixtures صغيرة فقط، لا على 5000 cut (R-03).

---

## 7. أقسام الذاكرة التي حدّثتها في `PROJECT_MEMORY.md`

| القسم | التغيير |
|---|---|
| ترويسة الملف | آخر تحقق صار مربوطًا بتنفيذ الدفعة الأولى |
| **§2 ما تم التحقق منه وحدود المعرفة** | فصل أرقام baseline التاريخية (81/7) عن نتائج ما بعد التنفيذ (135/2)، مع نص صريح أن لم يُشغّل أي جهاز/FFmpeg |
| **§1 الهوية والحالة المرجعية** | حصر المصدر: 134 ملف lib، 11 ملف test، مع التنبيه على عدم استبدال baseline |
| **§3 المعمارية** (جدول الخدمات المشتركة) | إضافة 4 صفوف للخدمات الجديدة |
| **§4 خريطة الخصائص — «إزالة السكتات»** | إعادة كتابة المسار من 1 إلى 10 بالترتيب الجديد؛ وصف guards الجديد؛ إضافة probe و`SilenceRemovalPlan`؛ الإشارة إلى أن `minSilenceDuration` لم يعد سياسة دمج وأن SR-06 باقٍ |
| **§7 قواعد التنفيذ** | تحديث القواعد 2، 5، 7، 9 لتعكس العقد الجديد (guard داخلي، الخطة canonical، إمكانية الحقن، وقياس native مطلوب لهذه الدفعة) |
| **§8 حالة المراجعة وخطة التعاون** | إضافة جدول حالة المشاكل (منفذ — بانتظار المراجعة / Open)، وتوضيح أن المراجع لا يرفع الحالة إلى «تم التحقق» إلا بفحص مستقل |
| **§10 سجل المتابعة** | إضافة سجل `2026-10-05 — OpenCode — الدفعة الأولى` بالنطاق، baseline المقاس قبل التنفيذ، التغييرات، الملفات، الاختبارات الفعلية، القيود، المتبقي، والحالة المسجلة |

**لم يُحذف أي سجل سابق.** لا يوجد `.git`، فلم أدّعِ diff نظيفًا ولم أنسب أي commit.

---

## 8. التوصية للمراجع

1. ابدأ بقراءة `PROJECT_MEMORY.md` من القرص، ثم افحص `IntervalAlgebra` و`SilenceRemovalPlan` و`MediaTimeline` و`SilenceDetectorRepositoryImpl.buildRemovalPlan` قبل الوثوق بأي رقم هنا.
2. **أهم نقطة للتدقيق:** هل تحويل guards من «توسعة» إلى «انكماش» هو قرار المنتج الصحيح؟ هو ما يطلب SR-02 صراحةً، لكنه **يغيّر سلوك المستخدم مرئيًا**: من «يضمن عدم بدايات مقطوعة» إلى «يحافظ على حافة الكلمة». مراجعته قرار منتجي لا مجرد إصلاح.
3. **النقطة الثانية:** مسار الـprobe لم يُختبر على جهاز. `MediaProbeDatasource` جديد بالكامل ولا أملك device للتحقق منه. الأولوية لاختباره على ملف به `start_time ≠ 0` ومسار صوتي متعدد.
4. **لا تعتمد على SR-06 كإصلاح.** SR-01 أُغلق على مستوى الدمج؛ لكن التمريرة الثانية بـ0.3s ثابتة ما زالت تقبل سكتات أقصر من حد المستخدم. هذه مخاطرة فقدان كلام مفتوحة ومقاسة على مستوى الوحدة فقط.
5. بعد المراجعة، حدّث الذاكرة بحالة **«تم التحقق»** مع تحديد نطاق التحقق، أو أعد البنود.
6. **لا تبدأ الدفعة B قبل ذلك.**
