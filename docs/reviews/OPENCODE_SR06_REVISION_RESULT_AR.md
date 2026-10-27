# استكمال SR-06 عند الحدود — OpenCode

- **التاريخ:** 2026-10-06
- **المنفّذ:** OpenCode
- **الحالة:** **منفذ — بانتظار مراجعة Codex.** لم تُعتمد SR-06 بعد؛ الحكم على هذا الاستكمال من Codex.
- **النطاق:** `docs/reviews/OPENCODE_SR06_REVISION_REQUEST_AR.md` وحده: SR06-R1 وSR06-R2.
- **المرجع السابق:** `docs/reviews/CODEX_SR06_REVIEW_AR.md` و`docs/reviews/OPENCODE_SR06_RESULT_AR.md`.
- **خارج النطاق ولم يُلمس:** VAD، سياسة threshold العامة، SR-04/07/08/10/11/16/21/22/23، الرسم، اختيار المسار الصوتي، cleanup، وملكية حالة التطبيق.

---

## 1. SR06-R1 — كان الحدّ يتسامح بمقدار زمني 1ms

### السبب الجذري

الجولة الأولى أزالت الحدّ الثابت `0.3` من التمريرة الثانية بنجاح، لكنها أضافت بدلًا منه **تخفيضًا زمنيًا 1ms** في شرط الحد:

```dart
static const double kMinSilenceLengthToleranceSeconds = 0.001;

return lengthSeconds >= minSilenceDuration - kMinSilenceLengthToleranceSeconds;
```

وهذا خاطئ في جوهره: المقارنة بين مدتين بالثواني تحتاج هامشًا **عدديًا** لا هامشًا زمنيًا. و1ms ليست «ضجيج تمثيل» بل فرق زمني حقيقي:

| الحالة | عند الحد 10ms | الحكم الصحيح | الحكم القديم |
|---|---:|---|---|
| 9.5ms | 0.5ms **أقصر** فعلًا | **رفض** | **قبول** ✗ |
| `0.3 - 0.1` عند الحد 0.2 | ناقص وحدة عائمة واحدة | قبول | قبول |

الحالة الأولى حذف صمتًا استبعده المستخدم صراحةً؛ والثانية كانت تُرفض لولا تخفيض 1ms لأن `0.3 - 0.1` = `0.19999999999999998` في IEEE-754، أي وحدة في آخر خانة أقل من `0.2`. الحل الصحيح يعالج الفرقين بصيغة واحدة: هامش عددي بعرض وحدات التمثيل نفسها.

### التنفيذ

حُذف `kMinSilenceLengthToleranceSeconds` واستُبدل بهامش نسبي معرَّف بالوحدات:

```dart
/// Headroom, in units in the last place, allowed below the configured minimum
/// when comparing a parsed silence length. **A numeric margin, not a duration.**
static const int kNumericToleranceUlps = 64;

/// Machine epsilon for IEEE-754 binary64, i.e. `2^-52`.
static const double _relativeUlp = 2.220446049250313e-16;

static double numericMarginFor(double minSilenceDuration) {
  final min = IntervalAlgebra.nonNegativeOrZero(minSilenceDuration);
  if (min <= 0) return 0;
  return min * kNumericToleranceUlps * _relativeUlp;
}

static bool satisfiesMinimumSilence(double lengthSeconds, double minSilenceDuration) {
  if (!lengthSeconds.isFinite) return false;
  final min = IntervalAlgebra.nonNegativeOrZero(minSilenceDuration);
  if (min <= 0) return true;
  return lengthSeconds >= min - numericMarginFor(min);
}
```

قيمة الهامش فعليًا عند حدود الواجهة:

| الحد | الهامش | بالمللي ثانية | عينة واحدة 16kHz |
|---|---:|---:|---:|
| 0.01s | 1.42e-16 s | 1.4e-13 ms | 6.25e-05 s |
| 0.25s | 3.55e-15 s | 3.6e-12 ms | 6.25e-05 s |
| 5s | 7.11e-14 s | 7.1e-11 ms | 6.25e-05 s |

الهامش **أصغر من 1ms بنحو 7.0e12 مرة** عند أصغر حد، وأصغر من عينة صوت واحدة 16kHz بنحو 4.4e8 مرة عند الحد 0.01s. أي أنه لا يمكن أن يصف زمنًا يميّزه الكاشف، بخلاف 1ms التي تعادل 16 عينة عند 16kHz.

تعليل الرقم: 64 وحدة في آخر خانة تغطي `0.3 - 0.1` (وحدة واحدة) وأي سلسلة عمليات قصيرة قابلة للمقارنة، وتبقى دون أي فرق زمني محسوس. وقد ثبت الاختبار أن 1e-12 نسبيًا (10 رتب أعلى من الهامش) **يُرفض**، بينما 32 وحدة في آخر خانة **تُقبل** — فالفصل عند حد التمثيل، لا عند حد زمني مُختار.

### تصحيح الاختبارات

اختبارات سياسة 1ms حُذفت واستُبدلت باختبارات دقة:

- الهامش موجب، وأصغر من 1e-12s، وأصغر من `min / 1e9` (أي ليس مللي ثانية ثابتة متنكّرة)، **ويتصاعد مع الحد** لا أن يكون ثابتًا.
- `0.0095` عند 0.01 **مرفوض** بالمساعد.
- `0.0095` عند 0.01 **مرفوض عبر الـdatasource الحقيقي** (سجل `silence_start: 2` / `silence_end: 2.0095`).
- `min * 0.999` و`min * 0.5` مرفوضة عند 0.01/0.25/2/5.
- `0.3 - 0.1` عند 0.2 **مقبول** بالمساعد، و**مقبول عبر الـdatasource** كفترة فعلية.
- حد مساوٍ تمامًا مقبول عند 0.01/0.25/2/5؛ وحد صفر أو سالب بلا هامش ويقبل كل شيء.
- طول غير finite مرفوض دائمًا.
- ضابط الدقة: 32 وحدة في آخر خانة مقبولة، و1e-12 نسبيًا مرفوض.

---

## 2. SR06-R2 — كان الفاصل الخلفي يشترط 50ms مستقلة

### السبب الجذري

عند إغلاق `silence_start` غير المنتهي عند نهاية النافذة كان الشرط:

```dart
if (currentStart != null &&
    fallbackEnd != null &&
    fallbackEnd > currentStart + 0.05) {
```

أي **سياسة قبول ثانية** غير مرتبطة بالحد الذي اختاره المستخدم. النتيجة: صمت خلفي 20ms عند حد 10ms — أطول من حدّ المستخدم ومن ثم مؤهَّل للحذف — كان يُسقَط بصمت. valeurs الظاهرة:

| المدة الخلفية | الحد | الحكم عند الحد | النتيجة القديمة |
|---|---:|---|---|
| 20ms | 10ms | مؤهَّل | **مفقود** ✗ |
| 49ms | 10ms | مؤهَّل | **مفقود** ✗ |
| 50ms | 100ms | غير مؤهَّل | مرفوض (لسبب خاطئ) |
| 20ms | 100ms | غير مؤهَّل | مرفوض (لسبب صحيح، بالمصادفة) |

### التنفيذ

أُزيل الحدّ المستقل. الآن يُغلق الفاصل متى كانت الفترة سليمة، ثم يطبّق الحد نفسه بعد التحليل:

```dart
if (currentStart != null && fallbackEnd != null) {
  final parsedStart = IntervalAlgebra.finiteOr(currentStart, fallback: double.nan);
  final parsedEnd = IntervalAlgebra.finiteOr(fallbackEnd, fallback: double.nan);
  final trailing = SilenceSegment(startSeconds: parsedStart, endSeconds: parsedEnd);
  if (trailing.isValid && trailing.startSeconds >= 0) segments.add(trailing);
}
```

- `finiteOr(..., fallback: double.nan)` بدل `fallback: 0`: لو كان أحد الحدّين غير مقروء فإن إرجاعه إلى `0` كان سيولّد صمتًا بطول النافذة كاملة. وبما أن `double.tryParse` يقبل `NaN` و`Infinity`، فإن الرجوع إلى `NaN` يُسقط الفترة بأمان بدل اختراع واحدة.
- `trailing.isValid` يفرض finite و`start < end`؛ و`startSeconds >= 0` يمنع فترة تبدأ خارج النافذة.
- **الحد يبقى وحيدًا**: `_rejectBelowMinimum` يطبّق `satisfiesMinimumSilence` على الفاصل الخلفي أيضًا، لأنه يمر بنفس مسار الفلاتر. لا أثر مزدوج ولا تكرار.

### الاختبارات المضافة

- المدد الخلفية **10/20/49/50/51/60/500/1500ms** عند حد 10ms: **كلها مقبولة** (قبل التصحيح كانت 10/20/49ms تسقط).
- المدد نفسها **10/20/49/50/51/60ms** عند حد 100ms: **كلها مرفوضة**.
- خلفية 3s عند حد 2s مقبولة؛ 1.5s عند حد 2s مرفوضة.
- فترة صفرية الطول (النافذة تنتهي عند بداية الصمت) لا تُركَّب.
- فترة تنتهي قبل بدايتها لا تُركَّب.
- نهاية نافذة غير finite (`NaN`) لا تُستخدم كحدّ.
- بداية صمت غير finite (`NaN`) لا تُستخدم كحدّ، ولا يختلق صمتًا بطول النافذة.
- بداية سالبة (`-5`) لا تُستخدم كحدّ.
- `silence_end` المكتمل ما زال يسلك فرعًا ولا يُغلق عند نهاية النافذة.

---

## 3. ما لم يتغيّر عمدًا

| العقد | الحالة |
|---|---|
| حد المستخدم في الأمرين | `d=<min>` في التمريرتين، وبلا `d=0.3` |
| فرق threshold بين التمريرتين | `kSecondPassThresholdOffsetDb = -10.0` كما هو |
| union | بلا معامل سماحية فجوة إطلاقًا؛ الفجوة الموجبة محتوى محفوظ |
| guards / breathing | لا يُفرض `minSilenceDuration` على طول الحذف النهائي |
| VAD | لم يُمس |
| الحد على السكتة الخام | حدّ اكتشاف فقط، وغالبًا بعد الحارس أقصر منه ومع ذلك يُحذف |

لم يتغيّر `test/silence_datasources_test.dart` في هذه الجولة: مثاله الحالي متوافق مع الحد الجديد ولم يعد يحتاج تعديلًا.

---

## 4. تصحيح تفسير الأدلة

طلب Codex في `OPENCODE_SR06_REVISION_REQUEST_AR.md` التنبيه إلى هذه النقطة صراحةً:

**مرجع waveform ليس دليلًا قبل/بعد لـSR-06.** الملف `docs/reviews/repro/codex_batch01_final_waveform_test.dart` (حالتان) يخصّ حفظ قمم الرسم وحافة الزمن في `waveform_viewer.dart` من الدفعة الأولى (B01-F1). لم يكن يومًا اختبارًا لحدّ المدة، ولم يتغيّر في هذه الجولة، ولم يُعدّل أي توقّع منه. أُعيد تشغيله هنا كـ**حارس عدم انحدار** فقط: الدليل الخاص بـSR-06 هو `codex_sr06_acceptance_test.dart` (5 حالات) واختبارات `test/silence_min_duration_test.dart` المملوكة لهذه المشكلة.

وكذلك، نجاح اختبارات `flutter test` يثبت سلوكًا على host، لا قياس وسائط: انظر القيود في القسم التالي.

---

## 5. الفحوصات المنفذة فعلًا

| الأمر | النتيجة |
|---|---|
| `flutter analyze --no-pub` | **No issues found!** (25.6s) |
| `flutter test --no-pub` | **290 ناجحًا** (267 + 23 جديدة)، 0 فاشلة |
| `flutter test --no-pub test/silence_min_duration_test.dart` | **51 ناجحًا** (كانت 28) |
| `flutter test --no-pub docs/reviews/repro/codex_sr06_acceptance_test.dart` | **5/5 ناجحة** (كانت 2 ناجحة / 3 فاشلة) |
| `flutter test --no-pub docs/reviews/repro/codex_batch01_acceptance_test.dart` | **7/7 ناجحة** |
| `flutter test --no-pub docs/reviews/repro/codex_batch01_revision_offsets_test.dart` | **3/3 ناجحة** |
| `flutter test --no-pub docs/reviews/repro/codex_batch01_final_waveform_test.dart` | **2/2 ناجحة** |
| `flutter test --no-pub docs/reviews/repro/silence_characterization_test.dart` | **2/2 ناجحة** (SR-08 وSR-12 المفتوحتان، بلا تغيير) |

إجمالي حالات القبول المحفوظة: **19** (14 سابقة + 5 جديدة). لم يُعدَّل أي ملف في `docs/reviews/repro/` ولا أي توقّع قبول، ولم تُستبدل سجلات Codex ولا `docs/reviews/REVIEW_BASELINE.json`.

السجلات الجديدة:

- `docs/reviews/OPENCODE_SR06_REVISION_ANALYZE_OUTPUT.txt`
- `docs/reviews/OPENCODE_SR06_REVISION_TEST_OUTPUT.txt`
- `docs/reviews/OPENCODE_SR06_REVISION_ACCEPTANCE_OUTPUT.txt`

### الملفات المعدَّلة (اثنان فقط)

- `lib/features/silence_detector/data/datasources/ffmpeg_silence_datasource.dart`
- `test/silence_min_duration_test.dart`

---

## 6. حدود التحقق — ما لم يُشغَّل

- **لا جهاز، ولا Android/iOS، ولا build.**
- **لا FFmpeg حقيقي:** `silencedetect` لم يُنفَّذ على أي ملف وسائط. كل النتائج أعلاه من **محاكاة قناة FFmpegKit** داخل `flutter test`، وهي تختبر بناء الأمر ومنطق الفترات على host.
- **لا encode، ولا probe، ولا ملف وسائط.** لا قياس A/V sync ولا جودة صوت ولا حماية كلام فعلي.
- **لم يُثبت** أن بناء FFmpeg حقيقي يطبع `silence_start` غير المنتهي، أو أن مخرجات `silencedetect` تلتزم بـ`d=` بالضبط على تسجيل عربي. «الفاصل الخلفي» افتراض معقول عن سلوك FFmpeg، ولم يُقاس.
- **مقارنة WAV/الفيديو** المقصودة في التعليقات عقد غير مقيس كما هي.
- راجعتُ `PROJECT_MEMORY.md` من القرص قبل التنفيذ، والذاكرة الآن تُحدَّث بحالة «منفذ — بانتظار مراجعة Codex».

---

## 7. الخطوة التالية

Codex يقرأ `PROJECT_MEMORY.md` من القرص، يراجع هذا التقرير والمصدر والأدلة المستقلة (خاصة `codex_sr06_acceptance_test.dart`)، ثم يسجّل حكمه ويحدّث الذاكرة. **لا تبدأ أي دفعة جديدة قبل ذلك.** تبقى SR-04/07/08/10/11/16/21/22/23 والبنود Open الأخرى على حالها.

**نقطة تستحق انتباه المراجع:** `numericMarginFor` يعتمد على `IntervalAlgebra.nonNegativeOrZero`، فحدّ غير finite يُعامَل كـ0 أي «بلا حدّ» بدل رفض كل المدد. هذا السلوك لم يتغيّر عن جولة SR-06 الأولى، والاختبار الجديد يثبته صراحةً. كما أن `kNumericToleranceUlps = 64` و`2^-52` اختياران محافظان؛ إن أراد Codex رقمًا أقرب إلى الحد الأدنى الضروري فذلك قراره بعد المراجعة، وقد فعّل الاختبار حدود الفصل عند 32 وحدة مقابل 1e-12 نسبيًا.
