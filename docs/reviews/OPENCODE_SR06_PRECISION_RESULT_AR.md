# استكمال دقة طرح الحدود SR06-R3 — OpenCode

- **التاريخ:** 2026-10-06
- **المنفّذ:** OpenCode
- **الحالة:** **منفذ — بانتظار مراجعة Codex.** الحكم على SR-06 من Codex، وقد قبل جولتَي R1 وR2 سابقًا ولا يُعاد فتحهما.
- **النطاق:** `docs/reviews/OPENCODE_SR06_PRECISION_REQUEST_AR.md` وحده: SR06-R3.
- **المرجع السابق:** `docs/reviews/CODEX_SR06_REVISION_REVIEW_AR.md`، `docs/reviews/OPENCODE_SR06_REVISION_RESULT_AR.md`.
- **خارج النطاق ولم يُلمس:** VAD، سياسة threshold العامة، SR-04/07/08/10/11/16/21/22/23، الرسم، اختيار المسار الصوتي، render، cleanup، وملكية حالة التطبيق.

---

## 1. السبب الجذري

الاختبار المستقل الجديد `docs/reviews/repro/codex_sr06_timestamp_precision_test.dart` كشف أن **قرار القبول يتغير بنقل السكتة على محور الزمن**، مع أن المدة العشرية واحدة:

| الفترة في السجل | المدة العشرية الصحيحة | قبل هذا التصحيح |
|---|---|---|
| `[0.01, 0.02]` | 0.01s | مقبولة |
| `[9.98, 9.99]` | 0.01s | **مرفوضة** |
| `[3600.01, 3600.02]` | 0.01s | **مرفوضة** |
| خلفية `silence_start: 3600.01` ونهاية نافذة 3600.02 | 0.01s | **مرفوضة** |
| `[3600.01, 3600.0195]` | 0.0095s | مرفوضة (صحيح) |

السبب أن `numericMarginFor(min)` كانت تحسب الهامش من **`min` وحدها**، بينما المقارنة الفعلية هي `end - start`. وخطأ تمثيل `start` و`end` — وهما نُصّان عشريان حُوِّلا إلى `double` — يكبر مع **موضع الفترة**، لا مع الحدّ:

| الموضع | ناتج الطرح | العجز عن 0.01 | هامش `min` وحده (السابق) |
|---|---:|---:|---:|
| `[0.01, 0.02]` | `0.01` | `0` | 1.42e-16 |
| `[9.98, 9.99]` | `0.00999999999999979` | 2.13e-16 | 1.42e-16 |
| `[3600.01, 3600.02]` | `0.009999999999763531` | **2.36e-13** | 1.42e-16 |
| `[360000.01, 360000.02]` | `0.0100000000093132` | −9.31e-12 (أطول) | 1.42e-16 |

العجز عند الساعة يقارب 1700 ضعف الهامش المحسوب من الحدّ وحده، ولذلك كان الرفض حتميًا. وهذا لا يخص ملفات طويلة استثنائية: العجز يظهر من الثانية العاشرة.

---

## 2. العقد المنفَّذ

### الاشتقاق

قرار `end - start >= min` يقرأ ثلاثة `double` من نصوص (`start` و`end` و`min`)، ولكل منها خطأ تمثيل حتى نصف وحدة في آخر خانة **من مقداره هو**، ثم يقرب الطرح مرة رابعة. إذًا:

```
خطأ الحساب <= (|start| + |end| + |min|) * 2^-52  +  0.5ulp(end-start)
```

والحدّ الحاكم هو مقدار **الحدود**، لأنها ما دُوّرت عنده. عدد الخطوات ثابت مشتقّ لا مضبوط:

```dart
/// 3 parsed bounds + 1 rounding of the difference. A count, not a tuned
/// constant, and not a duration in seconds.
static const int kBoundaryRoundingSteps = 4;

static const double _relativeUlp = 2.220446049250313e-16; // 2^-52

static double numericMarginFor(double scale) {
  final magnitude = IntervalAlgebra.nonNegativeOrZero(scale.abs());
  return magnitude * kBoundaryRoundingSteps * _relativeUlp;
}

static double numericMarginForInterval(
  double startSeconds,
  double endSeconds,
  double minSilenceDuration,
) {
  var scale = minSilenceDuration.isFinite ? minSilenceDuration.abs() : 0.0;
  for (final bound in [startSeconds, endSeconds]) {
    if (bound.isFinite && bound.abs() > scale) scale = bound.abs();
  }
  return numericMarginFor(scale);
}

static bool satisfiesMinimumInterval(
  double startSeconds,
  double endSeconds,
  double minSilenceDuration,
) {
  if (!startSeconds.isFinite || !endSeconds.isFinite) return false;
  final min = IntervalAlgebra.nonNegativeOrZero(minSilenceDuration);
  if (min <= 0) return true;
  final margin = numericMarginForInterval(startSeconds, endSeconds, min);
  return (endSeconds - startSeconds) >= min - margin;
}
```

### لماذا الرقم آمن

الهامش يتناسب مع الموضع، فيبقى أصغر من أي مدة يميّزها الكاشف:

| الموضع | الهامش | عينة واحدة 16kHz (62.5µs) |
|---|---:|---|
| `[0.01, 0.02]` | 1.78e-17 s | أصغر بنحو 3.5e12 مرة |
| `[9.98, 9.99]` | 8.87e-15 s | أصغر بنحو 7.0e9 مرة |
| `[3600.01, 3600.02]` | 3.20e-12 s | أصغر بنحو 2.0e7 مرة |
| عند 24 ساعة | 7.67e-11 s | أصغر بنحو 8.1e5 مرة |

ولبلوغ عينة واحدة كاملة كان يلزم طابع زمني في حدود `7e10` ثانية، أي نحو **2200 سنة**. وعند الحد الأدنى 10ms الهامش أصغر من 1ms بنحو **5.6e13 مرة**.

### الفصل قائم

الفرق بين «عجز تمثيل» و«مدة أقصر فعلًا» يبقى بحوالي **ثماني رتب عشريية**:

| الحالة عند min 0.01 | العجز | القرار |
|---|---:|---|
| `[3600.01, 3600.02]` | 2.36e-13 | **مقبول** (هامش 3.20e-12) |
| `[3600.01, 3600.0195]` | 5.00e-04 | **مرفوض** (هامش 3.20e-12) |

ولذا يرفض التنفيذ 9.5ms عند حد 10ms في المواضع نفسها التي قبلها كانت تُقبل عندها 10ms بالضبط.

---

## 3. أين يُطبَّق العقد

طلب Codex تحديدًا ألّا يُصلَح المحلل وحده. كلا موضعَي الفرض يمرّان بنفس العقد عبر `_rejectBelowMinimum`، فلم يبقَ مسار يعتمد على المدة المجرّدة:

| الموضع | السطر | المسار |
|---|---|---|
| بعد كل تمريرة | `ffmpeg_silence_datasource.dart:172` | `_runPass` → `_rejectBelowMinimum` → `satisfiesMinimumInterval` |
| قبل union | `ffmpeg_silence_datasource.dart:223` | `_mergeResults` → `_rejectBelowMinimum` → `satisfiesMinimumInterval` |

وتحقّق `lib/` كاملًا: لا يستعمل `satisfiesMinimumInterval`/`numericMargin*` خارج هذا الملف، ولا مكان آخر يفرض الحدّ على المدد. `_rejectBelowMinimum` كان يستدعي `satisfiesMinimumSilence(s.durationSeconds, ...)`؛ صار يستدعي `satisfiesMinimumInterval(s.startSeconds, s.endSeconds, ...)`.

### بقاء الدالة بلا حدود

`satisfiesMinimumSilence(length, min)` بُقيت كما هي لأن ملفَي قبول Codex يستدعيانها، لكنها صارت توثّق قيدها بوضوح: **هي فقدت الحدود** فتكتفي بتحجيم الهامش بـ`max(|length|, min)`، ويجب استعمال `satisfiesMinimumInterval` حيث الحدود معروفة. اختبار جديد يثبت عمليًا أن الشكلين يختلفان: الشكل بلا حدود **يقبل** `[0.01,0.02]` و**يرفض** `[9.98,9.99]` و`[3600.01,3600.02]` لسكتة 10ms واحدة، بينما شكل الفترة يقبل الثلاثة.

---

## 4. الاختبارات

### مُعدَّلة

- `test/silence_min_duration_test.dart` = **69 ناجحًا** (كانت 51).
- «الهامش وحدات في آخر خانة» صارت تؤكد الاشتقاق لا رقمًا مضبوطًا: `kBoundaryRoundingSteps == 4`، الهامش `> 0` و`< 1e-12` و`< scale / 1e9`، ويتصاعد مع المقدار لا مع الحدّ، ويظل دون عينة 16kHz عند 1s و1h و24h، والوصول لعينة واحدة يحتاج `> 1e10` ثانية.
- اختبار «ضجيج آخر خانة» أُعيد بناؤه: القبول عند الهامش المشتقّ نفسه، والرفض عند ألف ضعفه — لأن فرقًا بنسبة 0.1% من الهامش لا يوجد كـ`double` مختلف أصلًا.
- سُلّبت توقعات `kNumericToleranceUlps = 64` لأنها لم تعد موجودة؛ وثُبِّت بدلًا منها سلوك `numericMarginFor(-1) == numericMarginFor(1)` لأن الدالة صارت تأخذ **مقدارًا** لا حدًّا.

### مضافة (SR06-R3)

- سكتة عشرية 10ms **مقبولة** عند المواضع `0.01` و`9.98` و`3599.99` و`3600.01` و`86400.01` (قرب الصفر، 10s، ساعة، وأطول).
- سكتة 9.5ms **مرفوضة** عند المواضع نفسها نفسها.
- ضابط يثبت أن الشكل بلا حدود يختلف في الحكم حسب الموضع (يرفض موضعين من ثلاثة) بينما شكل الفترة يحكم بالتساوي.
- الهامش يكبر مع الحدود لا مع الحدّ.
- لكل حدّ من `0.01/0.25/2/5`: سكتة عشرية مساوية للحدّ **مقبولة** بعد ساعة، وسكتة **أقصر 5%** **مرفوضة** بعد ساعة.
- الفاصل الخلفي 10ms بعد ساعة **مقبول**.
- فاصل خلفي **يعبر الفرض الثاني**: تمريرة واحدة فقط تُبلّغ عنه، فالعقد الأخير قبل union هو ما يحسمه، ولولا تطابق العقدين لسقط.
- المسار الحقيقي عبر `SilenceDetectorRepositoryImpl` إلى `SilenceRemovalPlan` بـ`MediaTimeline` مدقّقة: `[3600.01,3600.02]` يُحذف و`[3600.01,3600.0195]` لا يُحذف عند min 10ms.

### الحالات السابقة المحفوظة

`9.5ms` مرفوضة عند 10ms بالمساعد وعبر الـdatasource، و`0.3 - 0.1` مقبول عند 0.2، و20ms خلفية عند 10ms مقبولة، وسكتة خام 2s عند min 2s تُقبل ثم يقلّصها guards إلى 0.5s وتُحذف رغم قصرها عن الحدّ، والفجوة الموجبة 10ms محفوظة، وفرق threshold 10dB ثابت.

---

## 5. ما لم يتغيّر

| العقد | الحالة |
|---|---|
| حدّ المستخدم في الأمرين | `d=<min>` في التمريرتين، وبلا `d=0.3` |
| فرق threshold | `kSecondPassThresholdOffsetDb = -10.0` |
| union | بلا معامل سماحية فجوة؛ الفجوة الموجبة محتوى محفوظ |
| guards / breathing | لا يُفرض الحدّ على طول الحذف النهائي |
| الفاصل الخلفي | بلا شرط 50ms؛ صلاحية finite و`start≥0` و`end>start` |
| VAD / SR-04 / render / stream selection | لم تُلمس |

الملفات المعدَّلة اثنان فقط: `lib/features/silence_detector/data/datasources/ffmpeg_silence_datasource.dart` و`test/silence_min_duration_test.dart`. لم يتغيّر `test/silence_datasources_test.dart`.

---

## 6. الفحوصات المنفذة فعلًا

| الأمر | النتيجة |
|---|---|
| `flutter analyze --no-pub` | **No issues found!** |
| `flutter test --no-pub` | **308 ناجحًا** (290 + 18)، 0 فاشلة |
| `flutter test --no-pub test/silence_min_duration_test.dart` | **69 ناجحًا** (كانت 51) |
| `flutter test --no-pub docs/reviews/repro/codex_sr06_timestamp_precision_test.dart` | **5/5 ناجحة** (كانت 2 ناجحة/3 فاشلة) |
| `flutter test --no-pub docs/reviews/repro/codex_sr06_acceptance_test.dart` | 5/5 ناجحة |
| `flutter test --no-pub docs/reviews/repro/codex_batch01_acceptance_test.dart` | 7/7 ناجحة |
| `flutter test --no-pub docs/reviews/repro/codex_batch01_revision_offsets_test.dart` | 3/3 ناجحة |
| `flutter test --no-pub docs/reviews/repro/codex_batch01_final_waveform_test.dart` | 2/2 ناجحة |
| `flutter test --no-pub docs/reviews/repro/silence_characterization_test.dart` | 2/2 ناجحة (SR-08 وSR-12 المفتوحتان) |

إجمالي حالات القبول المحفوظة: **24** (19 سابقة + 5 جديدة). لم يُعدَّل أي ملف في `docs/reviews/repro/` ولا أي توقّع قبول، ولم تُستبدل سجلات Codex ولا `docs/reviews/REVIEW_BASELINE.json`.

السجلات الجديدة: `docs/reviews/OPENCODE_SR06_PRECISION_{ANALYZE,TEST,ACCEPTANCE}_OUTPUT.txt`.

---

## 7. حدود التحقق — ما لم يُشغَّل

- **لا جهاز، ولا Android/iOS، ولا build.**
- **لا FFmpeg حقيقي:** `silencedetect` لم يُنفَّذ على أي ملف وسائط. كل ما سبق من **محاكاة قناة FFmpegKit** داخل `flutter test`.
- **لا encode، ولا probe، ولا ملف وسائط.** لا قياس A/V sync ولا جودة صوت ولا حماية كلام فعلي.
- **لم يُثبت** أن بناء FFmpeg حقيقي يطبع `silence_start` غير المنتهي، ولا أن مخرجات `silencedetect` تلتزم بـ`d=` بالضبط. الأرقام في القسم 1 **محسوبة في Dart** على تنفيذ المشروع، وCodex سجّل ذلك صراحةً؛ لا نزعم أن FFmpeg أنتج هذه السجلات على ملف مسجل.
- عقد محاذاة WAV/الفيديو يبقى غير مقيس، وشجرة `EditorScreen` لم تُضخ.
- **نطاق واحد لم يُختبر:** لم أفحص تراجعًا في الدقة عند قيم `minSilenceDuration` مستمدة من slider لا عشريات نظيفة. فارق التمثيل الفاصل بين قيمة الشريط والنص العشري هو من رتبة `ulp` في قيمة الشريط نفسه، وهو أصغر من الهامش المشتقّ، لكنه غير مقيس.

---

## 8. الخطوة التالية

Codex يقرأ `PROJECT_MEMORY.md` من القرص، يراجع هذا التقرير والمصدر و`codex_sr06_timestamp_precision_test.dart`، ثم يسجّل حكمه على SR-06 ويحدّث الذاكرة. **لا تبدأ أي دفعة جديدة قبل ذلك.** تبقى SR-04/07/08/10/11/16/21/22/23 والبنود Open الأخرى على حالها، وتبقى SR-06 في حالة «منفذ — بانتظار مراجعة Codex».
