# تقرير جولة تصحيح الدفعة الأولى — OpenCode

- **التاريخ:** 2026-10-05
- **المنفّذ:** OpenCode
- **الحالة:** **منفذة — بانتظار مراجعة Codex المستقلة. ليست معتمدة نهائيًا.**
- **النطاق:** `docs/reviews/OPENCODE_BATCH_01_REVISION_REQUEST_AR.md` فقط: B01-R1، B01-R2، B01-R3، B01-R4،+B01-C1.
- **خارج النطاق ولم يُلمس:** SR-04، SR-06، SR-07، SR-10، SR-11، SR-21، SR-22، SR-23، وكل الدفعات B/C/D/E. لم تبدأ الدفعة التالية.
- **قُرئ قبل العمل:** `PROJECT_MEMORY.md` من القرص، `docs/reviews/CODEX_BATCH_01_REVIEW_AR.md`، `docs/reviews/repro/codex_batch01_acceptance_test.dart`، وسجلات `docs/reviews/CODEX_BATCH_01_*_OUTPUT.txt`.

---

## 1. B01-R1 — أصل الزمن وإشارة إزاحة الصوت

**السبب الجذري (مؤكد في الكود قبل التعديل)**

`MediaProbeDatasource` كان يقرأ `start_time` مسار الصوت فقط ويضعه في `MediaTimeline.audioStartSeconds`، بينما `MediaTimeline.probed` كان يمرر الإزاحة عبر `nonNegativeOrZero` ثم `clamp(0, videoDuration)`، و`MediaProbeDatasource.parseSeconds` كان يرجع `0` لأي قيمة سالبة. النتيجة أن صفر الخط الزمني كان يُفترض صفرًا: ملف يبدأ عند 5s كان كل قص فيه يتزحزح 5s إلى اليمين، وبداية صوت سابقة للفيديو كانت تُمحى.

**التنفيذ**

1. **أصل صريح.** صفر الخط الزمني = `start_time` مسار الفيديو. يُقرأ من الـstream، ومع غيابه يُؤخذ من `format.start_time`، ومع غيابه `0`.
2. **إزاحة مسنّدة.** `audioStartSeconds = (audioOrigin ?? videoOrigin) - videoOrigin`. السالب يُحفظ. `MediaTimeline.probed` لم يعد يقصر الإزاحة على الصفر؛ صار يقصر **مقدارها** على مدة الفيديو ويبقي الإشارة.
3. **فصل نوعين من القراءة.** `parseTimestampSeconds(String?) -> double?` يقبل السالب ويرجع `null` لـ`N/A`/غير رقمي. `parseDurationSeconds(String?) -> double` يرجع `0` للسالب. المدة طول، و`start_time` رقم بإشارة.
4. **الازاحة تُطبَّق قبل القص.** `audioToVideoTimeline` يزيح ثم يطبّع على `[0, videoDuration]`. الصوت الذي يسبق الفيديو يُسقط جزؤه الخارج عن الفيديو ويُحتفظ بجزئه الداخلي بدل أن يُقص كـ`start` سالب.
5. **العقد نفسه في الاستخراج والقص**، موثّق في المصدر لا مُفترض:
   - `AudioProcessorRepositoryImpl.extractAudio`: بلا `-copyts` وبلا `-start_at_zero`، وحاوية WAV لا تحمل timestamps ⇒ عيّنة 0 هي أصل الصوت، فالإزاحة المقاسة هي بالضبط الفرق بين t=0 لهذا الملف وت=0 للفيديو.
   - `FfmpegCuttingService.cutWithConcat`: `trim`/`atrim` يقرآن الملف الأصلي بأصل الفيديو، والفترات وصلت إليه بعد تحويلها إلى ذلك الأصل.
   - **حدّ معلن:** اختيار المسار الصوتي ما زال ضمنيًا (`-map` غير موجود في الاستخراج، `[0:a]` في القص) بينما الـprobe يقيس أول مسار صوتي. ملف متعدد المسارات قد يُحلَّل على مسار ويُقصّ على آخر. هذا SR-23 (دفعة D)؛ لم أُصلحه لأنه خارج النطاق، وموثّق في الكود كحدّ.

**مثال قبل/بعد** (نفس الـmetadata، `MediaProbeDatasource` الفعلية بقناة محاكاة)

| الحالة | قبل | بعد |
|---|---|---|
| audio وvideo يبدأان عند 5s، silence `[1,2]` | removals `[6,7]` | **removals `[1,2]`**، offset `0` |
| audio يبدأ `-0.5` وvideo عند `0`، silence `[1,2]` | removals `[1,2]` (الإزاحة محيت) | **removals `[0.5,1.5]`**، offset `-0.5` |
| audio يبدأ `+0.5`، silence `[1,2]` | removals `[1.5,2.5]` (بالمصادفة) | **removals `[1.5,2.5]`**، offset `+0.5`Measured لا صدفة |

وفي حالة audio سابق: `[0.4,0.9]` ⇒ `[0,0.4]`، `[1.4,2]` ⇒ `[0.9,1.5]`، `[2.4,3.2]` ⇒ `[1.9,2.7]`، و`[0,0.2]` ⇒ `[-0.5,-0.3]` **تُسقط** لأنها خارج الفيديو تمامًا.

---

## 2. B01-R2 — إزالة ملء الفجوات الموجبة

**السبب الجذري:** `ffmpeg_silence_datasource.dart` كان يمرّر `gapToleranceSeconds = kPassBoundaryToleranceSeconds` (0.02) إلى `union`. الفارق بين 0 و20ms كانscheduled كـ«اهتزاز حدود عيّنات»، لكن 10ms = 160 عيّنة عند 16kHz، وقد تحمل بادية حرف أو انتقالًا قصيرًا. لا دليل أنها jitter فقط.

**التنفيذ**

- حُذف `kPassBoundaryToleranceSeconds` كليًا.
- حُذف معامل `gapToleranceSeconds` من `IntervalAlgebra.union`، و`IntervalAlgebra.normalize`، و`SilenceRemovalPlan.build`، و`SilenceDetectorRepositoryImpl.mergeOverlappingSegments`. **لم يبقَ مكان في المشروع يمكن تمرير سماحية فجوة إليه.** أي سياسة حذف محتوى بين فترتين تحتاج عقدًا منفصلًا ومراجعة مستقلة.
- `_mergeResults` في الـdatasource صار `union` خالصًا. `_parseSilenceOutput` يرفض الأزواج غير finite/المقلوبة (كان يفعل ذلك سابقًا أيضًا).
- `union` يدمج عند `current.start <= last.end` فقط: تداخل حقيقي أو تلامس عند الصفر.

**سلوك مثبَّت** (`:1/10/19/20/21/200ms`): كل الفجوات الموجبة محفوظة، والفجوة تظهر كـkept range في الخطة. التداخل والتلامس الحقيقيان لا يزالان يندمجان، ورفع `minSilenceDuration` إلى 5s لا يوسّع النتيجة.

---

## 3. B01-R3 — قائمة فارغة بعد الفلترة

**السبب الجذري:** `union` كانت تفحص `input.isEmpty` ثم تقرأ `sorted.first` بعد `where(isValid)`؛ قائمة غير فارغة من فترات غير صالحة كانت ترمي `Bad state: No element`. `complement` أيضًا كانت تكره الفترات غير الصالحة.

**التنفيذ**

- `union`: بعد الفرز، `if (sorted.isEmpty) return [];`.
- `complement`: يتخطى `!isValid`.
- `totalSeconds` والواجهات المفوّضة (`applyProtectedPadding`, `SilenceRemovalPlan.build`, `mergeOverlappingSegments`, `FfmpegSilenceDatasource.detectSilence`) ترث السلوك الصحيح لأن `union` هي نقطة الالتحاء الوحيدة.

**مثبَّت:** invalid-only ⇒ `[]` بلا استثناء؛ mixed ⇒ الفترات الصالحة فقط؛ `totalSeconds` = 0؛ `complement` يتخطى المعكوس؛ زوج log صفري/معكوس في الـdatasource ⇒ نتيجة فارغة بلا استثناء.

---

## 4. B01-R4 — waveform على المسطرة الحقيقية

**السبب الجذري:** `_drawWaveform` كان يوزع العينات على `size.width` كاملًا ويحسب `timeAtSample = (i / samples.length) * totalDuration`، متجاهلًا مدة الصوت وإزاحته. فيديو 10s بصوت 8s ⇒ قمة t=4s تُرسم عند t=5s. التلوين بمناطق الحذف والبحث بالضغط كانا على المحور الخاطئ أيضًا.

**التنفيذ**

`WaveformViewer` و`_WaveformPainter` يقبلان `audioDurationSeconds` و`audioStartSeconds`:
- `audioPixelWidth = audioSpan / totalDuration * size.width` — الصوت يشغل شريطه فقط.
- `audioTime = (i / samples.length) * audioSpan` ثم `videoTime = audioTime + audioStart`.
- `x = audioStartX + i * barWidth`، و`barWidth = audioPixelWidth / samples.length`.
- يُتخطّى أي عيّنة `videoTime < 0 || videoTime > totalDuration` ⇒ ما خارج الفيديو لا يُرسم، وما خارج الصوت يبقى فارغًا.
- تلوين مناطق الحذف يستخدم `videoTime` لا زمن الصوت.
- `onSeek` كما هو: `ratio * totalDuration` أي **زمن فيديو**، وهو المقياس نفسه.
- حارس تخصيص: `targetCount` محدود بـ20000.
- `editor_screen` يمرّر `audioDurationSeconds: _audioSpanSeconds(timeline)` (مدّة الـwaveform المقيسة، ومدّة الـprobe كاحتياط) و`audioStartSeconds: timeline.audioStartSeconds`.
- `shouldRepaint` شمل الحقلين الجديدين.

**قبل/بعد على بكسلات canvas حقيقية** (waveform بقمة عند t=4s من صوت 8s، مسطرة فيديو 10s/400px):

| الحالة | قبل | بعد |
|---|---|---|
| صوت 8s، بلا إزاحة | القمة عند x=200 | **x=160**؛ لا حبر بعد x=320 |
| صوت 4s معلن | القمة عند x=160 | **x=80** |
| إزاحة `+2s` | القمة عند x=160 | **x=240**؛ لا حبر قبل x=80 |
| إزاحة `-1s`، صوت 9s | القمة عند x=160 | **x=140** |
| منطقة حذف `[5,6]` + إزاحة `+2s` | لون عادي | **لون `waveformSilence`** (الأحمر مهيمن) لأن t=6s داخل المنطقة؛ بلا إزاحة يبقى `waveformColor` (الأزرق مهيمن) لأن t=4s خارجها |
| بحث بالضغط عند x=240 مع إزاحة `+2s` | — | **6.0s زمن فيديو** |

---

## 5. B01-C1 — ثبات الخطة (تحسين مقبول)

`SilenceRemovalPlan.build` صار يغلّف `removals` و`kept` بـ`List.unmodifiable`، والمُنشئ خاص، و`withoutRemoval` يبني خطة جديدة. اختبار مستقل عن تعديل قائمة المصدر بعد البناء.

---

## 6. الملفات المعدلة

### `lib/features/silence_detector/` (7)

| الملف | التغيير |
|---|---|
| `domain/services/interval_algebra.dart` | **إعادة كتابة**: حذف `gapToleranceSeconds` بالكامل؛ فحص فراغ القائمة بعد الفلترة؛ `complement` يتخطى غير الصالح؛ توثيق عقد «لا فجوة موجبة أبدًا» |
| `domain/entities/media_timeline.dart` | **إعادة كتابة**: إزاحة مسنّدة، توثيق الأصل والعقد مع الاستخراج/القص، `audioTimeToVideoTime`، `audioVisibleRange`، `copyWith` |
| `data/datasources/media_probe_datasource.dart` | **إعادة كتابة**: قراءة `start_time` الفيديو كالأصل، إزاحة مسنّدة، `parseTimestampSeconds`/`parseDurationSeconds` |
| `domain/entities/silence_removal_plan.dart` | قوائم غير قابلة للتعديل، حذف `gapToleranceSeconds` |
| `data/datasources/ffmpeg_silence_datasource.dart` | حذف ثابت السماحية؛ دمج بلا فجوة؛ ملاحظات |
| `data/repositories/silence_detector_repository_impl.dart` | توثيق الإزاحة المسنّدة؛ `mergeOverlappingSegments` بلا معامل |
| `presentation/widgets/waveform_viewer.dart` | **إعادة كتابة**: نافذة صوت بإزاحة مسنّدة، لا تمديد، تلوين على زمن الفيديو |

### `lib/` خارج النطاق وظيفيًا (2 — توثيق عقد فقط)

| الملف | التغيير |
|---|---|
| `audio_processing/.../audio_processor_repository_impl.dart` | توثيق عقد الخط الزمني على `extractAudio` + إعلان حدّ SR-23 |
| `video_processing/.../ffmpeg_cutting_service.dart` | توثيق عقد الخط الزمني على `cutWithConcat` + إعلان حدّ SR-23 |
| `video_processing/presentation/editor_screen.dart` | تمرير `audioDurationSeconds`/`audioStartSeconds` إلى الـwaveform + `_audioSpanSeconds` |

### اختبارات (`test/`)

| الملف | الحالة | العدد |
|---|---|---|
| `silence_interval_algebra_test.dart` | معدَّل: كتل B01-R2 (6 أحجام فجوة + 1ns + touch/overlap) وB01-R3 (6 حالات)؛ حُذف اختبار «سماحية صريحة» | **38** |
| `silence_removal_plan_test.dart` | معدَّل: كتل إزاحة مسنّدة incl. pre-roll straddling وround-trip؛ كتلة B01-C1 | **24** |
| `silence_detection_pipeline_test.dart` | معدَّل: بداية مشتركة غير صفرية، صوت سابق، نافذة discoveries | **14** |
| `silence_datasources_test.dart` | **جديد**: الـdatasourceان الفعليان عبر قناة FFmpegKit محاكاة — 6 أحجام فجوة، تداخل/تلامس، minSilence، أزواج log منحرفة، 9 حالات probe، عقدا التحليل | **27** |
| `silence_waveform_rendering_test.dart` | **جديد**: 12 اختبار رسم على بكسلات canvas حقيقية (موضع، إزاحة ±، نافذة، تلوين، بحث، حالات حدّ) | **12** |

المجموع في `test/`: **196 ناجحًا** (135 قبل التصحيح + 61 جديدة).

### أدوات مراجعة Codex — لم تُعد كتابة

- `docs/reviews/repro/codex_batch01_acceptance_test.dart` **لم يُمس**. توقّعاته كما كتبها Codex.
- `docs/reviews/CODEX_BATCH_01_{ACCEPTANCE,ANALYZE,TEST,LEGACY_REPRO}_OUTPUT.txt` **لم تُمس**. هذه هي دليل «قبل» (1 ناجح / 6 فاشلة).

### سجلات هذه الجولة (أسماء جديدة)

- `docs/reviews/OPENCODE_BATCH_01_REVISION_ANALYZE_OUTPUT.txt`
- `docs/reviews/OPENCODE_BATCH_01_REVISION_TEST_OUTPUT.txt`
- `docs/reviews/OPENCODE_BATCH_01_REVISION_ACCEPTANCE_OUTPUT.txt`
- `docs/reviews/OPENCODE_BATCH_01_REVISION_LEGACY_REPRO_OUTPUT.txt`

---

## 7. الاختبارات والنتائج الفعلية

| الأمر | النتيجة الحرفية |
|---|---|
| `flutter analyze --no-pub` | `No issues found! (ran in 5.8s)` |
| `flutter test --no-pub` | `00:09 +196: All tests passed!` |
| `flutter test --no-pub test/silence_interval_algebra_test.dart` | `+38` |
| `flutter test --no-pub test/silence_removal_plan_test.dart` | `+24` |
| `flutter test --no-pub test/silence_detection_pipeline_test.dart` | `+14` |
| `flutter test --no-pub test/silence_datasources_test.dart` | `+27` |
| `flutter test --no-pub test/silence_waveform_rendering_test.dart` | `+12` |
| `flutter test --no-pub docs/reviews/repro/codex_batch01_acceptance_test.dart` | **`00:00 +7: All tests passed!`** (كانت `+1 -6`) |
| `flutter test --no-pub docs/reviews/repro/silence_characterization_test.dart` | `+2` (SR-08، SR-12 — لم تتغير) |
| `python tools/review_inventory.py` | `Indexed 147 Dart files, 25573 lines.` |

### قبل/بعد لكل ملاحظة

| الملاحظة | قبل (سجل Codex) | بعد (هذه الجولة) | الاختبار الثابت |
|---|---|---|---|
| B01-R1 حالتان | فاشلتان | ناجحتان | `silence_datasources_test.dart` (9 حالات probe) + `silence_removal_plan_test.dart` + `silence_detection_pipeline_test.dart` |
| B01-R2 | فاشلة | ناجحة | `silence_datasources_test.dart` (1/10/19/20/21/200ms على الـdatasource الفعلي) + `silence_interval_algebra_test.dart` |
| B01-R3 | فاشلة | ناجحة | `silence_datasources_test.dart` (أزواج log منحرفة) + `silence_interval_algebra_test.dart` (invalid-only/mixed/واجهات) |
| B01-R4 | فاشلة | ناجحة | `silence_waveform_rendering_test.dart` (12 اختبار بكسل) |
| B01-C1 | فاشلة | ناجحة | `silence_removal_plan_test.dart` (3 اختبارات) |

**لم تُعد كتابة أي توقّع في ملف القبول.** لم تُحذف أي حالة مفتوحة من `silence_characterization_test.dart`.

---

## 8. القيود — ما لم يُشغَّل

لم أُنفّذ ولا أزعم:

- **لا build ولا تشغيل على جهاز** لـAndroid/iOS. `EditorScreen` لم تُفتح فعليًا، ولا slider ولا زر.
- **لا تنفيذ لـFFmpeg**: لا `silencedetect`، ولا extract، ولا encode، ولا probe على ملف. **`MediaProbeDatasource` لم تُختبر على وسائط حقيقية؛ تُختبر بقناة plugin محاكاة تعيد dictionaries.** يبقى سؤال مفتوح: هل FFprobe يعيد `start_time` على مستوى الـstream في كل الحاويات (MP4/MKV/MOV/TS)؟ هذا **غير مُقاس**.
- **لا قياس A/V sync، ولا جودة صوت، ولا دقة نقطة قطع، ولا VFR/portrait/SAR.**
- **اختبار الرسم نجح على بكسلات canvas على host**، لا على فيديو مُشغَّل. لا يثبت أن الملف الناتج يطابق الصوت.
- **لا مقارنة Git diff**: لا `.git` في هذه النسخة. بصمات `REVIEW_BASELINE.json` لم تُحدَّث؛ `SOURCE_INVENTORY.md` أُعيد توليده (147 ملفًا).
- **حدّ الفاصلة العشرية:** اختبار الإزاحة السالبة في خط الأنابيب يقارن بـ`closeTo` لأن `1.4 - 0.5 = 0.8999999999999999`. السلوك صحيح، والخطأ العائم محصور بالقياس لا بالترتيب.

### أثر جانبي يجب أن يعلمه المراجع

`dart format` نُفِّذ على `lib/features/silence_detector` و`lib/features/video_processing`، وعلى `audio_processor_repository_impl.dart`. هذا مسّ **خمسة ملفات خارج نطاق التصحيح** بتغييرات مسافات فقط (≤3 أسطر لكل):

| الملف | أسطر قبل → بعد |
|---|---|
| `silence_detector/data/services/vad_service.dart` | 100 → 103 |
| `silence_detector/data/services/adaptive_threshold_service.dart` | 71 → 73 |
| `silence_detector/domain/entities/detection_params.dart` | 90 → 89 |
| `video_processing/presentation/processing_screen.dart` | 159 → 156 |
| `video_processing/data/services/ffmpeg_smart_zoom_service.dart` | 20 → 19 |

لم أستطع التراجع عنها بدقة: لا Git في هذه النسخة، وإعادة كتابة الملفات من الذاكرة كانت ستخاطر بتغيير دلالي. التغييرات **تنسيقية فقط**، و`flutter analyze` و`flutter test` خضراء بعدها.

---

## 9. ما بقي مفتوحًا

| البند | الحالة | ملاحظة |
|---|---|---|
| **SR-06** | Open | **الأخطر.** التمريرة الثانية ما زالت `minSilenceDuration: 0.3` ثابتة، فسكتة 0.4s تُحذف عند `min=2s`. R2 أزال ملء الفجوات فقط ولم يفرض حد المستخدم على التمريرة الثانية. مخاطرة فقدان كلام مفتوحة. |
| SR-04 | Open | `silenceRemovalPlanProvider` ما زال عامًّا بلا هوية ملف. |
| SR-07 | Open | تعديل guards/threshold لا يُبطل الخطة القديمة. |
| SR-21 | Open | `_requireRemovablePlan` ما زال حاجزًا نصيًا لا نتيجة typed. |
| SR-10/11/22/23 | Open | القص ذو جزء واحد، وتقدّم التصدير بالثواني، ومعنى Original، واختيار المسار الصوتي. |
| **SR-23 (محدد)** | Open، **موثّق في الكود** | الاستخراج بلا `-map` والقص بـ`[0:a]`. موقّع كحدّ في `extractAudio` و`cutWithConcat` بدل إصلاح صامت. |
| R-03 (آلاف القطعات) | Open | لا قياس RAM/سرعة على 5000 cut. |

**قرار منتجي لم يتغيّر:** Speech Guard (انكماش داخل السكتة) باقٍ كما اعتُمد؛ لم ألمسه في هذه الجولة.

---

## 10. التوصية للمراجع

1. اقرأ `PROJECT_MEMORY.md` من القرص أولًا، ثم افحص `IntervalAlgebra` (هل حذف معامل السماحية كامل؟)، و`MediaProbeDatasource` + `MediaTimeline` (هل العقد المكتوب يطابق ما يفعله FFmpeg فعلًا؟)، و`WaveformViewer`.
2. **أهم نقطة لم تُختبر:** هل FFprobe يعيد `start_time` على مستوى الـstream في كل الحاويات التي يعالجها التطبيق؟ الاختبار كله محاكاة. أولوية لملف MP4/MKV حقيقي يبدأ عند ≠0 على جهاز.
3. **ثاني نقطة:** `_audioSpanSeconds` يفضّل مدّة الـwaveform المقيسة على مدّة الـprobe. إن اختلفت (مثل `-copyts` مستقبلي)، يجب مراجعة أيّهما يتبع الرسم.
4. **ثالث نقطة:** تحقّق من حذف `gapToleranceSeconds` من كل الاستدعاءات — `rg` يجب أن يعيد صفرًا. هذا مقصود: منع تكرار B01-R2.
5. **أثر `dart format`**: وازِن بين فائدة التنسيق وحجم التغييرات الإضافي؛ قد تفضّل إبقاءه أو طلب استرجاع يدوي.
6. بعد المراجعة حدّث الذاكرة بحالة **«تم التحقق»** مع تحديد نطاق التحقق (والحقيقة أن نطاق التحقق هنا **حسابي + رسم على host، لا أصلي**)، أو أعد البنود.
7. **لا تبدأ الدفعة B قبل ذلك.**
