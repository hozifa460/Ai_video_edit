# تقرير جولة تعديلات العرض والرسائل — OpenCode

- **التاريخ:** 2026-10-05
- **المنفّذ:** OpenCode
- **الحالة:** **منفذة — بانتظار مراجعة Codex المستقلة. ليست معتمدة نهائيًا.**
- **النطاق:** `docs/reviews/OPENCODE_BATCH_01_UI_CORRECTION_REQUEST_AR.md` فقط — B01-F1 وB01-F2.
- **حُفظ ولم يُمس:** إصلاح B01-R1 المتحقق (الإزاحة كما قيس، التقاطع الصريح، القص بعد التحويل، سياسة الرفض) وحكم Codex السابق على SR-01/02/03/19. **لم أبدأ الدفعة التالية**، وبقيت SR-06/04/07/10/11/21/22/23 مفتوحة.
- **قُرئ قبل العمل:** `PROJECT_MEMORY.md` من القرص، `docs/reviews/CODEX_BATCH_01_FINAL_REVIEW_AR.md`، `docs/reviews/repro/codex_batch01_final_waveform_test.dart`، وسجلات `CODEX_BATCH_01_FINAL_*_OUTPUT.txt`.

---

## 1. B01-F1 — كان Painter يُسقط قممًا

### السبب الجذري المؤكَّد

`waveform_viewer.dart` كان يحسب `stride` ثم يقرأ `source[i]` فقط مع `i += stride`:

```dart
final availableColumns = (size.width * waveformZoom).ceil()...;
final stride = count > availableColumns * 2 ? (count / (availableColumns * 2)).ceil() : 1;
for (var i = 0; i < count; i += stride) { ... source[i] ... }
```

هذا **إسقاط عينات لا تجميع**. عند 2000 عينة وعرض 400px وzoom 1 يكون `stride = 3`، فتمرّ 0/3/6… وتختفي البقية تمامًا. النتيجة: قمة عند العينة 999 تظهر وقمة عند 1000 تختفي — أي أن مظهر الملف يتغير بتغير موضع القمة عينة واحدة، رغم أن الصوت متطابق. وهذا يخالف ما كتبته في جولة الاستكمال («الأثر البصري مطابق»)؛ وقد صحّح Codex ذلك.

خطأ ثانٍ في نفس السطر: `size.width` مضروبًا في `waveformZoom`، بينما `WaveformViewer` يمرّر للـPainter حجمًا **يحتوي التكبير بالفعل** (`constraints.maxWidth * waveformZoom`)، فالتكبير يُطبَّق مرتين في حساب كثافة الأعمدة.

### التنفيذ

استُبدل الـstride بـ**اختزال (decimation) حقيقي يحفظ القمم**:

1. كل عينة تُوضع في **عمود البكسل الذي تقع فيه فعلًا**: `column = floor(videoTime / totalDuration * columnCount)`.
2. عند تشابه عدة عينات في عمود واحد، يفوز **أكبر قيمة مطلقة**، ويُحفظ معه **زمن تلك العينة** لقيادة التلوين بمناطق الحذف.
3. `size.width` يُستخدم كما هو (يحتوي التكبير)، وحُذف الضرب الثاني.
4. `waveformZoom` لم يعد يدخل حساب عدد الأعمدة إطلاقًا.
5. أُزيل استعمال `getDownsampledSamples` من هذا الـPainter (يبقى مستعملًا في `media_cutter_screen.dart` خارج النطاق — لم يُلمس).
6. الحالات الحدّية محفوظة: ما يقع خارج `[0, totalDuration]` يُتخطى ولا يُقصّ على حافة (سلوك B01-R1 محفوظ).

### قبل/بعد على بكسلات canvas حقيقية

| الحالة | قبل | بعد |
|---|---|---|
| قمة واحدة عند العينة 1000 / 2000 عينة / 400px | **لا حبر إطلاقًا** | حبر كامل في العمود 200 |
| قمة عند العينة 999 | حبر | حبر (لم ينكسُر) |
| 3 قمم (0.3، 1.0، 0.2) في عمود واحد | العمود يأخذ 0.3 فقط | العمود يصل إلى y=4 بارتفاع 1.0 |
| تكبير 8× | `size.width` مضروبًا بالـzoom مرتين | القمة عند x=2400 على ruler بعرض 3200 |
| عرض 120px | — | القمة محفوظة |
| إشارة كثيفة 2000 عينة كاملة السعة | أعمدة مسطحة متناوبة | لا عمود مسطح |

ملف Codex `docs/reviews/repro/codex_batch01_final_waveform_test.dart` (كما كتبه حرفيًا): **2/2 ناجحة** (كانت 1 ناجح/1 فاشل).

---

## 2. B01-F2 — سبب الرفض لم يصل للمستخدم، وترتيب الأسباب كان خاطئًا

### السبب الجذري المؤكَّد

عيبان منفصلان:

1. **الشاشة**: `_detectSilence` كانت تفحص `!timeline.isDetectable` وتعرض رسالة واحدة لكل الحالات: «Cannot detect silence: this file has no readable duration or no audio track». بعد أن أصبح `isDetectable` يشترط التقاطع، ملفٌّ مدته صحيحة ومساره الصوتي موجود وبلا تقاطع يصل للمستخدم بهذه الرسالة الخاطئة. ورسالة `does not overlap` الجديدة في المستودع **لا تمرّ أصلًا** بهذا الطريق، لأن `_detectSilence` يعود قبل استدعاء `buildRemovalPlan`.
2. **المستودع**: كان يختار السبب بـ`hasDetectionWindow` قبل فحص صلاحية المدة، فيصنّف ملفًا مدته `0` وصوته موجود على أنه «لا تقاطع» بدل «لا مدة».

### التنفيذ — عقد واحد للطرفين

كيان جديد `lib/features/silence_detector/domain/entities/silence_detection_blocker.dart`:

```dart
enum SilenceDetectionBlocker {
  unusableMediaDuration,   // FFprobe gave no usable video duration
  missingAudioTrack,       // no audio stream
  noAudioVideoOverlap,     // audio exists, duration fine, but windows never meet
}
```

و`SilenceDetectionGate` بثلاث دوال:
- `blockerFor(timeline)` — **ترتيب ثابت**: المدة ← المسار الصوتي ← التقاطع. أول تطابق يفوز. فحص التقاطع قبل المدة كان الخطأ المحدد.
- `canDetect(timeline)` — اختصار.
- `messageFor(blocker)` — نص واحد لكل سبب، ورسائله متمايزة وموجّهة للمستخدم.

الاستهلاك:
- `SilenceDetectorRepositoryImpl.buildRemovalPlan` يستبدل سلسلته ad-hoc بـ`blockerFor` + `messageFor` ويعيد `SilenceDetectionFailure` بنفس النص.
- `EditorScreen._detectSilence` يستدعي `EditorScreen.detectionBlockedMessage(timeline)` وهي نقطة دخول **ثابتة على الـwidget** تستعمل `blockerFor`/`messageFor` نفسيهما، ثم تعرض النص في SnackBar.
- `MediaTimeline.isDetectable` لم يتغيّر منطقه؛ يبقى `duration > 0 && hasAudio && hasDetectionWindow`، واختبار في `test/` يثبت تطابقه مع `SilenceDetectionGate.canDetect` على مصفوفة من 7 خطوط زمنية حتى لا تتفرّق الطبقتان.

### قبل/بعد

| الحالة | نص الشاشة قبل | نص المستودع قبل | الآن (واحد) |
|---|---|---|---|
| مدة غير صالحة | «no readable duration or no audio track» | «audio does not overlap…» (خطأ) | **«This file has no readable duration, so nothing can be cut»** |
| لا مسار صوتي | نفس الرسالة المدمجة | «File has no audio stream to analyse» | **«This file has no audio track to analyse»** |
| تقاطع فارغ | نفس الرسالة المدمجة (خطأ) | «audio does not overlap…» | **«The audio does not overlap the video, so there is no speech synchronised with picture to analyse»** |

**سياسة الرفض لم تتغير** كما طُلب: غياب تقاطع يبقى رفضًا صريحًا، لا خطة فارغة.

---

## 3. الملفات المعدلة

| الملف | التغيير |
|---|---|
| `silence_detector/presentation/widgets/waveform_viewer.dart` | **إعادة كتابة `_drawWaveform`**: decimation يحفظ القمم،Envelope + زمن لكل عمود، حذف مضاعفة الـzoom، حذف `getDownsampledSamples` من هذا الـPainter |
| `silence_detector/domain/entities/silence_detection_blocker.dart` | **جديد** — enum + بوابة أسباب مرتّبة + رسائل |
| `silence_detector/data/repositories/silence_detector_repository_impl.dart` | استعمال `SilenceDetectionGate` بدل سلسلة شروط ad-hoc |
| `silence_detector/presentation/editor_screen.dart` | `EditorScreen.detectionBlockedMessage(timeline)` ثابتة + SnackBar بالسبب المحدد |

### الاختبارات

| الملف | التغيير |
|---|---|
| `test/silence_waveform_rendering_test.dart` | **أُعيد بناؤه** بكتلتين: `B01-R4 the waveform sits on the video ruler` (16 اختبارًا) و`B01-F1 decimation preserves peaks` (9: قمم 999/1000/1001/1999، عرض 120px، zoom 8×، أعمدة متعددة تفوز بالأقصى، قمة على حد التقاطع، نشاط بعد نهاية الفيديو، إشارة كثيفة) ⇒ **25** |
| `test/silence_detection_blocker_test.dart` | **جديد** — 18 اختبارًا: ترتيب الأسباب، تطابق `canDetect` مع `isDetectable` على 7 خطوط، تطابق نص الشاشة مع نص `SilenceDetectionFailure` لكل سبب، ورسالة مرئية داخل SnackBar حقيقي |

المجموع في `test/`: **239 ناجحًا** (211 + 28).

### لم يُمس

- `docs/reviews/repro/codex_batch01_final_waveform_test.dart` — كما كتبه Codex.
- `codex_batch01_acceptance_test.dart`, `codex_batch01_revision_offsets_test.dart`, `silence_characterization_test.dart`.
- كل سجلات `CODEX_BATCH_01_*` و`CODEX_BATCH_01_REVISION_*` و`CODEX_BATCH_01_FINAL_*`.
- `docs/reviews/REVIEW_BASELINE.json`، وكل ما يخص B01-R1 وSR-01/02/03/19 وSR-06 وبقية البنود.

### سجلات هذه الجولة

`OPENCODE_BATCH_01_UI_{ANALYZE,TEST,WAVEFORM,ACCEPTANCE}_OUTPUT.txt`.

---

## 4. الاختبارات والنتائج الفعلية

| الأمر | النتيجة الحرفية |
|---|---|
| `flutter analyze --no-pub` | `No issues found! (ran in 19.3s)` |
| `flutter test --no-pub` | `00:26 +239: All tests passed!` |
| `flutter test --no-pub docs/reviews/repro/codex_batch01_final_waveform_test.dart` | `00:01 +2: All tests passed!` (كانت `+1 -1`) |
| `flutter test --no-pub docs/reviews/repro/codex_batch01_acceptance_test.dart docs/reviews/repro/codex_batch01_revision_offsets_test.dart docs/reviews/repro/silence_characterization_test.dart` | `00:01 +12: All tests passed!` (7 + 3 قبول، و2 أمثلة مفتوحة) |
| `python tools/review_inventory.py` | `Indexed 149 Dart files, 26564 lines.` |

**قبل/بعد:**

| القياس | قبل | بعد |
|---|---|---|
| `codex_batch01_final_waveform_test.dart` | 1 ناجح / 1 فاشل | **2/2** |
| اختبارات المشروع | 211 | **239** |
| ملفات القبول الأخرى (12 حالة) | 12 | **12** (لم تنقص) |

لم تُعد كتابة أي توقّع في أي ملف Codex.

---

## 5. القيود — ما لم يُشغَّل

لم أُنفّذ ولا أزعم:

- **لا build ولا تشغيل على جهاز** لـAndroid/iOS.
- **لا تنفيذ لـFFmpeg**: لا probe على ملف، ولا encode، ولا `trim`/`atrim`. لا قياس A/V sync ولا جودة صوت.
- **الرسم مُختبَر على بكسلات canvas على host**، لا على فيديو مُشغَّل.
- **شجرة `EditorScreen` كاملة لم تُضخَّ في الاختبار.** تحتاج `VideoPlayerPlatform`، وهي غير متاحة في `flutter test` دون إضافة `plugin_platform_interface` كاعتمادية dev — وهو **تجاوزٌ لنطاق الطلب**. لذلك اختبرتُ المسار المرئي عبر `EditorScreen.detectionBlockedMessage`، وهي نقطة الدخول التي تستدعيها `_detectSilence` نفسها، مع **إثبات تطابق حرف‑بحرف** بين نصها ونص `SilenceDetectionFailure` القادم من المستودع، وعرض النص داخل `SnackBar` حقيقي عبر `find.text`. هذا يثبت الرسالة可以达到 المستخدم وي断定 تطابق الطبقتين، لكنه **ليس** تشغيلًا للشاشة الكاملة.
- **قياس أداء الرسم على جهاز لم يُنفَّذ**: الـPainter يمرّ على كل عينة المصدر (حتى 2000) ويملأ ثلاثة `List` بطول عدد الأعمدة. الأثر البصري مثبت، والسرعة وسلاسة التمرير غير مقيسة — ضمن SR-16 كما اتفق عليه Codex.
- **لا مقارنة Git diff**؛ بصمات `REVIEW_BASELINE.json` لم تُحدَّث، و`SOURCE_INVENTORY.md` أُعيد توليده.
- **`dart format`** نُفِّذ على `lib/features/silence_detector` وملف `silence_detection_blocker.dart` الجديد واختبارَي `test/` الجديدين فقط. **لم يُضف churn خارج النطاق** في هذه الجولة.

---

## 6. ما بقي مفتوحًا

| البند | الحالة |
|---|---|
| **SR-06** | Open — **الأخطر.** التمريرة الثانية ما زالت `minSilenceDuration: 0.3` ثابتة. |
| SR-04، SR-07، SR-21 | Open — لم تُلمس. خطر إبقاء خطة ملف سابق (SR-04) مستقل عن هذه الجولة، كما طلب Codex. |
| SR-10/11/22/23 | Open — لم تُلمس؛ SR-23 ما زال حدًّا موثقًا (اختيار المسار الصوتي ضمني). |
| **SR-16** | Open — قياس أداء الرسم على جهاز لازم الآن بعد تغيير خوارزمية الرسم. |
| **SR-05 / B01-R1** | الحكم السابق محفوظ؛ **ما زال يحتاج قياس وسائط** (تزامن A/V، دقة القص). |
| **مطابقة أصول WAV/الفيديو** | عقد مقصود غير مقيس. لم يتغيّر في هذه الجولة. |

**قرار المنتج لم يتغيّر:** Speech Guard، رفض الكشف بلا تقاطع، وتوحيد الخطة — كلها كما اعتُمدت.

---

## 7. التوصية للمراجع

1. اقرأ `PROJECT_MEMORY.md` من القرص، ثم افحص `_drawWaveform` (هل فعلاً decimation لا stride؟ `rg stride lib/` يجب أن يعطي صفرًا في هذا الملف) و`SilenceDetectionGate` و`EditorScreen.detectionBlockedMessage`.
2. **تحقّق أني لم أضعف عقد B01-R1 أثناء إعادة كتابة الرسم**: الحالات الحدّية (ما قبل الفيديو، ما بعده، على الحد) ما زالت مختبَرة في نفس الملف.
3. **نقطة تستحق حكمك:** `size.width` في الـPainter يحتوي التكبير، فعدد الأعمدة يتضاعف مع zoom تلقائيًا. هذا يعني أن التكبير يضيف دقة فعلية (كان يرفعها الـstride paradoxically). السلوك صحيح لكنه يغيّر كثافة الأعمدة عند التكبير، وهو قرارك.
4. **الفجوة التي لم أُغلقها**: شجرة `EditorScreen` غير مختبَرة. إن أردت إغلاقها، فالمطلوب اعتمادية dev واحدة واختبار يحقن `VideoPlayerPlatform`. لم أُضفها لأنه خارج النطاق.
5. **SR-16 يستحق جدولة**: خوارزمية الرسم تغيّرت، وفعلًا لا يوجد قياس سرعة بعد التغيير.
6. بعد المراجعة حدّث الذاكرة بحالة **«تم التحقق»** مع تحديد نطاق التحقق — وهو **رسم على host + منطق خالص، لا أصلي** — أو أعد البنود.
7. **لا تبدأ الدفعة التالية قبل ذلك.**