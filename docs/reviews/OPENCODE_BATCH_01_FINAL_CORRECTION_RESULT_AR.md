# تقرير جولة استكمال B01-R1 — OpenCode

- **التاريخ:** 2026-10-05
- **المنفّذ:** OpenCode
- **الحالة:** **منفذة — بانتظار مراجعة Codex المستقلة. ليست معتمدة نهائيًا.**
- **النطاق:** `docs/reviews/OPENCODE_BATCH_01_FINAL_CORRECTION_REQUEST_AR.md` فقط — استكمال B01-R1 / SR-05.
- **خارج النطاق ولم يُلمس:** SR-04، SR-06، SR-07، SR-10، SR-11، SR-21، SR-22، SR-23، وكل الدفعات B/C/D/E. **لم تبدأ الدفعة التالية.**
- **قُرئ قبل العمل:** `PROJECT_MEMORY.md` من القرص، `docs/reviews/CODEX_BATCH_01_REVISION_REVIEW_AR.md`، `docs/reviews/repro/codex_batch01_revision_offsets_test.dart`، وسجلات `docs/reviews/CODEX_BATCH_01_REVISION_*_OUTPUT.txt`.

---

## 1. السبب الجذري المؤكَّد في الكود

`MediaTimeline.probed` كان يحدّ الإزاحة إلى مدى الفيديو:

```dart
var offset = IntervalAlgebra.finiteOr(audioStartSeconds, fallback: 0);
if (offset > video) offset = video;
if (offset < -video) offset = -video;
```

الإزاحة **قياسٌ لأين يقع أصل الصوت نسبةً إلى أصل الفيديو، وليست مدة**. وقد تتجاوز مدة الفيديو بصورة صحيحة تمامًا: فيديو يبدأ عند `start_time = 12` وطوله 10s، وصوت يبدأ عند `0` ويمتد 22s ⇒ الإزاحة `−12`. تقصيرها إلى `−10` لا يقفّر قيمة مجهولة؛ يعيد تأريخ كل فترة في الملف.

**قبل الإصلاح (مُقاس على التنفيذ الفعلي):**

| الحالة | الصحيح | الفعلي قبل |
|---|---|---|
| video10s، audio22s، offset−12، silence `[13,14]` | `[1,2]` | **`[3,4]`** |
| video10s، audio11s، offset−12، silence `[10,11]` | لا حذف (`[-2,-1]` خارج الفيديو) | **حذف `[0,1]`** — مثبَّت على الحافة |
| video10s، audio يبدأ `+12` | الإزاحة 12 ونافذة تقاطع فارغة | **الإزاحة تحوّلت إلى 10** |

الحالة الثانيةreveal نوعين من الخلل في آن: إزاحة مشوّهة، **ثم** `IntervalAlgebra.normalize` تثبّت الفاصل `[-2,-1]` على `0` فاخترعت ثانية من الحذف.

كما كان `test/silence_removal_plan_test.dart` يحتوي اختبارًا بعنوان `an offset larger than the timeline is capped in magnitude` **يثبت السياسة الخاطئة نفسها** — أي أن نجاح 196 اختبارًا لم يكن يغطي هذا السلوك بل كان يثبته.

---

## 2. ما نُفِّذ

### 2.1 الحفاظ على مقدار الإزاحة المقاس

`MediaTimeline.probed` لم يعد يلمس الإزاحة إلا_when تكون غير finite:

```dart
audioStartSeconds: IntervalAlgebra.finiteOr(audioStartSeconds),
```

- أي إزاحة finite تُحفظ بإشارتها ومقدارها بلا أي حدّ.
- القيمة غير الـfinite (NaN/Infinity) وحدها ترجع 0، لأن حينها تكون **مجهولة** لا **مقيسة**.

### 2.2 التقاطع الفارغ معالَج صراحةً

أُضيف `({double startSeconds, double endSeconds})? detectionWindow()`:

- نافذة الصوت تبدأ عند أصل الصوت (0 = t=0 للـWAV المستخرج) وتنتهي عند مدّة الصوت المقيسة، أو عند نهاية الفيديو إن كانت المدّة مجهولة.
- كلا الطرفين يُحوَّل إلى محور الفيديو ثم **يُتقاطَع** مع `[0, videoDurationSeconds]`.
- **تعيد `null` عند عدم وجود تقاطع** — صوت ينتهي قبل بداية الفيديو، أو يبدأ بعد نهايته. هذه حالة حقيقية فارغة، وليست خطأً، ولا تستدعي اختراع أصل بديل.

مشتقّاتها:
- `detectionWindowEndSeconds` / `detectionWindowStartSeconds` ⇒ `0` عند غياب التقاطع، وغير سالبة دائمًا.
- `hasDetectionWindow` لاختبار صريح.
- `audioVisibleRange()` ⇒ `null` عند غياب التقاطع (بدل range وهمية).
- `isDetectable` صار `videoDurationSeconds > 0 && hasAudio && hasDetectionWindow`.

### 2.3 القصّ بعد التحويل

`audioToVideoTimeline` يزيح أولًا (`videoTime = audioTime + offset`) ثم يطبّع على مدة الفيديو، فالنتيجة **تُقصّ بعد التحويل** كما هو مطلوب. الفاصل الذي يقع خارج الفيديو يُسقطه `normalize` بدل تثبيته على الحافة — فلا يُخترع حذف.

### 2.4 رفض صريح في خط الأنابيب

`SilenceDetectorRepositoryImpl.buildRemovalPlan` يرفض قبل أي عمل:

- بلا تقاطع ⇒ `SilenceDetectionFailure('The audio stream does not overlap the video timeline; there is nothing that can be cut against picture')`.
- بلا صوت ⇒ `'File has no audio stream to analyse'`.
- بلا مدّة فيديو ⇒ `'Media timeline is unusable: no readable video duration'`.

لم تعد هناك خطة فارغة أو Silent عند غياب تقاطع.

### 2.5 الرسم على المسطرة الصحيحة

`_drawWaveform` سابقًا كان يعتمد على `getDownsampledSamples(audioPixelWidth)` ثم يستنتج الزمن من **طول ناتج-eye الدالة** — وهو غير موثوق لأن الدالة ترجع `samples` كما هي عندما `targetCount >= samples.length`، وتخطّي الشرائح الفارغة خلاف ذلك. استُبدل ذلك بموضع يُشتق مباشرةً من المصدر:

```
stepAudio = audioSpan / count
videoTime = audioStart + i * stepAudio      // اصطلاح الحافة اليسرى
x         = (videoTime / totalDuration) * size.width
if (videoTime < 0 || videoTime > totalDuration) continue;
```

اصطلاح الحافة اليسرى يطابق `WaveformData.getSampleAtTime` القائم في المشروع. ولمنع حلقة غير محدودة عند تكبير شديد، أُضيف `stride` صحيح يُقلّل عدد الأعمدة إلى عدد أعمدة البكسل التقريبي **مع بقاء المواضع دقيقة** (خطوة صوتية = `i * stride / count * span`). أُزيل استعمال `getDownsampledSamples` من الـPainter.

النتيجة: pre-roll أطول من الفيديو يُرسم بموضعه الحقيقي، وصوت لا يلتقي الفيديو إطلاقًا **لا يُرسم ولا يُقصّ على الحافة**.

### 2.6 تصحيح التعليقات (البند 4)

| الموضع | قبل | بعد |
|---|---|---|
| `media_timeline.dart` | «`detected - audioStartSeconds` converts back to this timeline» | قسم **Conversion direction**: `videoTime = audioTime + audioStartSeconds`؛ والطرح mentioned كعكس في `videoToAudioTimeline` فقط |
| `audio_processor_repository_impl.dart` | «`detected - audioStartSeconds` converts a detected interval back» + «agree by construction» | **الاتجاه صحيح**، ومطابقة الأُصل موسومة **«intended contract, not a verified one»** مع ذكر: الأوامر لم تُنفَّذ على وسائط، سياسة الـtimestamps وdecoder priming غير مقيسة، والذاكرة تحفظ **الفرق** لا **الأصل المطلق** اللازم لإعادة اشتقاقه |
| `ffmpeg_cutting_service.dart` | تعليق «Timeline contract» قصير بلا توجّه صريح | نفس المعالجة: اتجاه صحيح + **Unmeasured** صريح + SR-23 كحدّ |

لم أنقل أي ادعاء تزامن A/V إلى نص التحقق.

---

## 3. الملفات المعدلة

| الملف | التغيير |
|---|---|
| `silence_detector/domain/entities/media_timeline.dart` | **القلب**: إلغاء تقصير الإزاحة، `detectionWindow()` nullable + مشتقّاته، `audioVisibleRange()` nullable، `isDetectable` يتطلّب تقاطعًا، توثيق اتجاه التحويل والعقد غير المقيس، مثال offset−12 في التعليق |
| `silence_detector/data/repositories/silence_detector_repository_impl.dart` | رفض صريح مميّز لثلاث حالات، منها غياب التقاطع |
| `silence_detector/presentation/widgets/waveform_viewer.dart` | موضع العيّنات من المصدر مباشرةً + `stride` صحيح، وإزالة `getDownsampledSamples` من الـPainter |
| `audio_processing/.../audio_processor_repository_impl.dart` | **تعليق فقط**: اتجاه التحويل + العقد غير المقيس |
| `video_processing/.../ffmpeg_cutting_service.dart` | **تعليق فقط**: اتجاه التحويل + القيود. (أُعيد `import ffmpeg_kit.dart` بعد خطأ Greater في تحرير السطور — تحقّقت أنه موجود وأن `analyze` نظيف) |

### الاختبارات

| الملف | التغيير |
|---|---|
| `test/silence_removal_plan_test.dart` | استُبدل اختبار السياسة الخاطئة باثنين صحيحين؛ **+8** في كتلة `B01-R1 follow-up` (pre-roll أطول، صوت قبل الفيديو، صوت بعد الفيديو، مدّة صوت تتجاوز الفيديو، مدّة مجهولة، round-trip بمقدار كبير، فيديو غير صالح) ⇒ **32** |
| `test/silence_datasources_test.dart` | **+2** على الـprobe الحقيقي: إزاحة −12 تنجو، ولا تقاطع من جهتين ⇒ **29** |
| `test/silence_detection_pipeline_test.dart` | **+2**: رفض بلا تقاطع برسالة `does not overlap`، وpre-roll أطول من الفيديو عبر repository ⇒ **16** |
| `test/silence_waveform_rendering_test.dart` | **+3** رسم ببكسلات حقيقية: pre-roll أطول (ذروة عند x=160 لا x≈291)، صوت قبل الفيديو (لا حبر)، صوت بعد الفيديو (لا حبر) ⇒ **15** |

المجموع في `test/`: **211 ناجحًا** (196 قبل الجولة + 15).

### لم يُمس

- `docs/reviews/repro/codex_batch01_revision_offsets_test.dart` — **كما كتبه Codex حرفيًا**.
- `docs/reviews/repro/codex_batch01_acceptance_test.dart` — كما هو.
- `docs/reviews/repro/silence_characterization_test.dart` — SR-08 وSR-12 مفتوحتان كما كانتا.
- كل سجلات `CODEX_BATCH_01_*` و`CODEX_BATCH_01_REVISION_*`.
- `docs/reviews/REVIEW_BASELINE.json`.

### سجلات هذه الجولة (أسماء جديدة)

`OPENCODE_BATCH_01_FINAL_{ANALYZE,TEST,OFFSETS,ACCEPTANCE}_OUTPUT.txt`.

---

## 4. الاختبارات والنتائج الفعلية

| الأمر | النتيجة الحرفية |
|---|---|
| `flutter analyze --no-pub` | `No issues found! (ran in 6.2s)` |
| `flutter test --no-pub` | `00:22 +211: All tests passed!` |
| `flutter test --no-pub docs/reviews/repro/codex_batch01_revision_offsets_test.dart` | `00:00 +3: All tests passed!` (كانت `+0 -3`) |
| `flutter test --no-pub docs/reviews/repro/codex_batch01_acceptance_test.dart` | `+7` (لم تنقص) |
| `flutter test --no-pub docs/reviews/repro/silence_characterization_test.dart` | `+2` (لم تنقص) |
| الملفات الفرعية | `silence_removal_plan_test.dart` = 32، `silence_datasources_test.dart` = 29، `silence_detection_pipeline_test.dart` = 16، `silence_waveform_rendering_test.dart` = 15، `silence_interval_algebra_test.dart` = 38 |
| `python tools/review_inventory.py` | `Indexed 147 Dart files, 25999 lines.` |

### قبل/بعد

| القياس | قبل | بعد | سجل |
|---|---|---|---|
| حالات offsets في ملف Codex | 0/3 | **3/3** | `OPENCODE_BATCH_01_FINAL_OFFSETS_OUTPUT.txt` مقابل `CODEX_BATCH_01_REVISION_OFFSETS_OUTPUT.txt` |
| اختبارات المشروع | 196 | **211** | `OPENCODE_BATCH_01_FINAL_TEST_OUTPUT.txt` |
| 7 القبول الأصلية | 7/7 | **7/7** | لم تُمس التوقعات |
| 2 الأمثلة المفتوحة | 2/2 | **2/2** | لم تُمس |

`rg "detected - audioStartSeconds"` على `lib/` يعيد صفرًا — لا يتبقى تعليق بالاتجاه المعكوس.

---

## 5. القيود — ما لم يُشغَّل

لم أُنفّذ ولا أزعم:

- **لا build ولا تشغيل على جهاز.** `EditorScreen` لم تُفتح فعليًا.
- **لا تنفيذ لـFFmpeg**: لا `silencedetect`، ولا extract، ولا encode، ولا `trim`/`atrim`، ولا probe على ملف. الـprobe مُختبَر بقناة plugin محاكاة تُعيد dictionaries.
- **لا قياس A/V sync، ولا جودة صوت، ولا دقة نقطة قطع.**
- **الرسم مُختبَر على بكسلات canvas على host**، لا على فيديو مُشغَّل.
- **لا مقارنة Git diff**: لا `.git`؛ بصمات `REVIEW_BASELINE.json` لم تُحدَّث، و`SOURCE_INVENTORY.md` أُعيد توليده.
- **العقد الزمني لم يُقَس على وسائط.** أهم سؤال مفتوح: هل FFmpeg يعيد `start_time` على مستوى الـstream في كل الحاويات (MP4/MKV/MOV/TS)، وهل أصل الـWAV المستخرج يطابق `audio.start_time` المقاس فعلًا؟ Declared as an intended contract, **not** verified.
- **أثر `dart format`:** نُفِّذ على `lib/features/silence_detector` وملفَّي `ffmpeg_cutting_service.dart` و`audio_processor_repository_impl.dart` فقط. **لم يُضف churn جديد خارج النطاق** هذه المرة (الدورة السابقةDeclaration عن 5 ملفات ما زالت قائمة كما هي).

---

## 6. ما بقي مفتوحًا

| البند | الحالة |
|---|---|
| **SR-06** | Open — **الأخطر.** التمريرة الثانية ما زالت `minSilenceDuration: 0.3` ثابتة، فسكتة 0.4s تُحذف عند `min=2s`. لم يمسّه هذا الاستكمال. |
| SR-04، SR-07، SR-21 | Open — لم تُلمس. |
| SR-10/11/22 | Open — لم تُلمس. |
| **SR-23** | Open، **موثّق كحدّ** في الاستخراج والقص. اختيار المسار الصوتي ضمني. |
| **SR-05 / B01-R1** | **منفذ هندسيًا — بانتظار مراجعة Codex.** بقي القياس الأصلي مطلوبًا: SR-05 في قائمته الأصلية كان P1 لأن المدة كانت من الـwaveform؛/Duration صارت من الـprobe، لكن **دقة القص وA/Vync لم تُقَس على جهاز**. |
| R-03 (5000 cut) | Open — لا قياس RAM/سرعة. |

**قرار المنتج لم يتغيّر:** Speech Guard (انكماش داخل السكتة) باقٍ كما اعتُمد في الدفعة الأولى.

---

## 7. التوصية للمراجع

1. اقرأ `PROJECT_MEMORY.md` من القرص أولًا، ثم افحص `MediaTimeline.probed` (هل بقي أي تقصير؟ `rg` يجب أن يعطي صفرًا لكل `clamp` على الإزاحة) و`detectionWindow()` و`buildRemovalPlan` و`_drawWaveform`.
2. **أهم نقطة تبقى غير مُقاسة:** عقد تطابق أصول WAV/الفيديو/المسار الصوتي. التعليقات الآن تصفه كعقد مقصود وغير مُثبت — تحقّق أنني لم أقلب الوعد إلى ادعاء، **و** أن قياسه يبقى مدرجًا كحد.
3. **نقطة تستحق حكمك:** تحويل `isDetectable` ليشترط التقاطع يجعل ملفات «صوت لا يلتقي الفيديو» تُرفض برسالة. هذا سلوك مستخدم جديد. بديل كان خطة فارغة + رسالة «لا سكتات». اختر الأ appropriate.
4. **نقطة أداء:** الـPainter صار يرسم حتى 2000 عيّنة (أو عدد أعمدة البكسل بعد `stride`) بدل downsampling إلى عرض الشاشة. الأثر البصري مطابق، لكنه ليس قياس أداء على جهاز — SR-16 مفتوحة أصلًا.
5. `dart format` هذه الجولة: تحقّق أن `ffmpeg_cutting_service.dart` لم يفقد أي import (عدّلت يدويًا.import وأعدت `ffmpeg_kit.dart`؛ `analyze` نظيف).
6. بعد المراجعة حدّث الذاكرة بحالة **«تم التحقق»** مع تحديد نطاق التحقق — وهو **حسابي + رسم على host، لا أصلي** — أو أعد البنود.
7. **لا تبدأ الدفعة التالية قبل ذلك.**
