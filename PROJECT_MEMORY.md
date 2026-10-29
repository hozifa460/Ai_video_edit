# ذاكرة المشروع الدائمة — AI Video Studio

آخر مراجعة: **2026-10-27 — OpenCode: دفعة إصلاح الحشو والقص والـVAD — «منفذ — بانتظار مراجعة Codex»**. 349 اختبارًا وanalyze نظيف؛ لم يُجرَّ تحقق وسائط أو جهاز. أحدث حكم مستقل سابق هو مراجعة B1 بتاريخ 2026-10-22 (SR-04/SR-07 متحققتان جزئيًا، بقي R1/R3/R4)، والدفعة الأولى وSR-06 معتمدتان ضمن نطاقهما السابق. اقرأ الذاكرة من القرص قبل كل مراجعة وحدّثها بعدها وفق `AGENTS.md`.

## 1. الهوية والحالة المرجعية

- حزمة Flutter: `ai_video_editing`، الإصدار `1.0.0+1`، Dart SDK المطلوب `^3.10.1`.
- الاسم في التطبيق: **AI Video Studio**. توجد أسماء تاريخية: `SilenceRemoverApp` و`AppConstants.appName = Silence Remover` و`ai_video_editing` في Android.
- تطبيق تحرير وسائط محلي أساسًا: إزالة السكتات، القص، محرر صوت، تحسين الصوت، تعديل الفيديو، تحسين الفيديو، وإنشاء Shorts.
- لا يظهر backend أو نظام حسابات أو API لنموذج لغوي في المصدر. الإنترنت يُستخدم للاستيراد المباشر وYouTube. كلمة AI في الواجهة لا تعني وجود نموذج توليدي: معظم التحليل قواعد وFFmpeg، والتعرف على الوجوه يستخدم ML Kit.
- الجذور الموجودة: `lib/`, `test/`, `android/`, `ios/`, `web/`. لا توجد مجلدات runners لـWindows/macOS/Linux في هذه النسخة. وجود `web/` لا يثبت جاهزية الويب؛ المسارات الأساسية تستورد `dart:io` وتستخدم إضافات أصلية.
- النسخة المحلية ليست مستودع Git عند الفحص. لا توجد مقارنة commits متاحة؛ انظر بصمات الملفات في `docs/reviews/REVIEW_BASELINE.json`.
- حصر المصدر الحالي:138 ملف Dart في lib و20 ملف اختبار في test؛158 إجمالًا. أُعيد توليد SOURCE_INVENTORY بواسطة `python tools/review_inventory.py` في جولة 2026-10-27:158 ملفًا و29789 سطرًا. لم تُستبدل REVIEW_BASELINE.json التاريخية.

## 2. ما تم التحقق منه وحدود المعرفة
- **جولة OpenCode بتاريخ 2026-10-27 (بانتظار مراجعة Codex):** نُفِّذت دفعة الحشو/القص/VAD على المصدر. `flutter analyze --no-pub` = **No issues found**؛ `flutter test --no-pub --reporter compact` = **349 ناجحًا**؛ ملفات repro الستة المتصلة بالسلامة = **23 ناجحًا/1 فاشل**. الفشل الوحيد في `codex_sr06_acceptance_test.dart` هو `expect(commands, hasLength(2))` لأن الدفعة أزالت التمريرة الثانية المطلوبة؛ توقّع خطة الحذف نفسه نجح، ولم يُعدَّل ملف القبول. `silence_characterization_test.dart` بقي **2/2** (SR-08 وSR-12 مفتوحتان). لا جهاز/build/FFmpeg/وسائط أو قياس A/V. التفاصيل في سجل 2026-10-27 أدناه.
- **مراجعة Codex المستقلة لتصحيح B1 بتاريخ 2026-10-22:** قُرئت الذاكرة من القرص وفُحص المصدر. `flutter test --no-pub --reporter expanded` = **317 ناجحًا**؛ `flutter analyze --no-pub` = **No issues found**؛ ملفات القبول السابقة بما فيها B1 = **34 ناجحة**. أضيف `docs/reviews/repro/codex_batch_b1_revision_acceptance_test.dart`: **7 حالات، 1 ناجح و6 فاشلة** (فشلان لهوية ناتج المعالجة، 3 لتداخل Auto، وفشل لعزل عرض الخطة، وضابط ناجح لطلب كشف قديم لا يوقف الأحدث). السجلات `CODEX_BATCH_B1_REVISION_{TEST,ANALYZE,LEGACY_ACCEPTANCE,ACCEPTANCE}_OUTPUT.txt`. R5 متحقق، وأجزاء R1/R2/R3/R4 تحسنت؛ بقي R1/R3/R4. لا تغيير lib بواسطة Codex ولا تبديل لتوقعات القبول السابقة أو baseline. المتحكم وwidget فعليان مع خدمات محكومة الإكمال؛ الشاشة الكاملة لم تُضخ، ولا build أو جهاز أو FFmpeg أو وسائط أو قياس A/V.
- **مراجعة Codex لـB1 بتاريخ2026-10-22:** أعيد تشغيل317 اختبارًا بنجاح وanalyze نظيف و24 حالة سابقة ناجحة. قبول مستقل جديد `docs/reviews/repro/codex_batch_b1_acceptance_test.dart` =1 ناجح/9 فاشلة (3 render،1 حالةكشف،3 Auto،1 widget fallback،1 بوابةأسباب،وضابطناجح). السجلات `CODEX_BATCH_B1_{TEST,ANALYZE,ACCEPTANCE,LEGACY_ACCEPTANCE}_OUTPUT.txt`. لا تعديلlib؛ اختباروتوثيق فقط. لاEditorScreen كاملة أو جهاز أوFFmpeg أووسائط. الحكم الحالي تصحيحB1-R1..R5.
- **اعتماد Codex واستكمال التوثيق بتاريخ2026-10-22:** قُرئت الذاكرة من القرص وفُحص عقد حدود الفترة واستدعاءاته، وأعيد تشغيل `flutter test --no-pub --reporter expanded` =308 ناجحة، و`flutter analyze --no-pub` =No issues found، وملفات القبول الستة =24 ناجحة (22 حالة قبول صحيحة السلوك +مثالين يثبتان SR-08/SR-12 المفتوحتين). سجلات جديدة `CODEX_SR06_CLOSEOUT_20261022_{TEST,ANALYZE,ACCEPTANCE}_OUTPUT.txt`؛ سجلات2026-10-06 محفوظة. لا تعديل lib أو توقعات الاختبارات، ولا تحقق جهاز أو وسائط. حكم الاعتماد محدد بالمصدر والحساب والمحاكاة على host.

- بيئة الفحص: Windows، Flutter **3.38.3**، Dart **3.10.1**.
- نتائج المراجعة الأصلية (2026-10-05، قبل أي إصلاح إنتاجي): `flutter test --no-pub` = **81 ناجحًا**، `flutter analyze --no-pub` = **No issues found**، وأمثلة `docs/reviews/repro/` = **7 ناجحة تثبت العيوب**. هذه أرقام baseline تاريخية ولا تصف الحالة الحالية.
- نتائج تنفيذ الدفعة الأولى (منفذ): `flutter analyze --no-pub` = **No issues found**؛ `flutter test --no-pub` = **135 ناجحًا**؛ `docs/reviews/repro/silence_characterization_test.dart` = **2 ناجحة** (SR-08 وSR-12 المفتوحتان). تقرير التنفيذ: `docs/reviews/OPENCODE_BATCH_01_RESULT_AR.md`.
- **تحقق Codex المستقل اللاحق:** 135 ناجحًا وanalyze نظيف؛ اختبار قبول `docs/reviews/repro/codex_batch01_acceptance_test.dart` = **7 حالات، 1 ناجحة و6 فاشلة** (R1 حالتان، R2/R3/R4/C1 حالة لكل منها). سجل Codex الأصلي في `docs/reviews/CODEX_BATCH_01_*_OUTPUT.txt` ويجب ألّا يُستبدل.
- **جولة التصحيح (منفذ — بانتظار مراجعة Codex):** بعد معالجة B01-R1..R4 وB01-C1 صارت `flutter analyze --no-pub` = **No issues found**، و`flutter test --no-pub` = **196 ناجحًا** (135 + 61 جديدة)، واختبار قبول Codex = **7/7 ناجحة**، وأمثلة `docs/reviews/repro/silence_characterization_test.dart` = 2 ناجحة كما كانت. سجل هذه الجولة في `docs/reviews/OPENCODE_BATCH_01_REVISION_*_OUTPUT.txt`؛ تقرير التصحيح `docs/reviews/OPENCODE_BATCH_01_REVISION_RESULT_AR.md`.
- **مراجعة Codex المستقلة لجولة التصحيح:** أعيد تشغيل196 اختبارًا بنجاح، وanalyze نظيف، وملف القبول الأصلي7 + الأمثلة2 =9 ناجحة. اختبار إضافي `docs/reviews/repro/codex_batch01_revision_offsets_test.dart` = **3 فاشلة**: تقصير الإزاحة−12 إلى−10 لفيديو10s ينقل الحذف أو يخترع حذفًا من صوت سابق بالكامل. السجلات `CODEX_BATCH_01_REVISION_*_OUTPUT.txt` لم تُستبدل.
- **جولة الاستكمال (منفذ — بانتظار مراجعة Codex):** بعد إزالة تقصير الإزاحة صارت `flutter analyze --no-pub` = **No issues found**، `flutter test --no-pub` = **211 ناجحًا** (196 + 15)، `codex_batch01_revision_offsets_test.dart` = **3/3 ناجحة** (كانت 0/3)، `codex_batch01_acceptance_test.dart` = **7/7**، `silence_characterization_test.dart` = **2**. سجل هذه الجولة `OPENCODE_BATCH_01_FINAL_*_OUTPUT.txt`؛ تقرير الاستكمال `docs/reviews/OPENCODE_BATCH_01_FINAL_CORRECTION_RESULT_AR.md`.
- **مراجعة Codex المستقلة للاستكمال:** أعيد تشغيل211 اختبارًا بنجاح، وanalyze نظيف، وجميع ملفات القبول السابقة =12 ناجحة (7+3 قبول و2 أمثلة مفتوحة). اختبار الرسم الجديد `docs/reviews/repro/codex_batch01_final_waveform_test.dart` = **1 ناجح/1 فاشل**: stride يخفي قمة المصدر1000 ويعرض999 عند2000 عينة/400px. سجلات هذه المراجعة `CODEX_BATCH_01_FINAL_*_OUTPUT.txt`؛ لا تغيير لتوقعات القبول القديمة أو سجلات الجولات السابقة. B01-F2 مثبت بتتبع شروط الشاشة والمستودع، لا تشغيل واجهة على جهاز.
- **نجاح اختبارات القبول يعني التنفيذ على محاكاة قناة FFmpeg/FFprobe وعلى رسم widget على host، لا على وسائط حقيقية ولا جهاز.** تبقى قيود القياس الأصلية كما هي: لم يُشغّل Android/iOS، ولا encode، ولا ملف وسائط، ولا قياس A/V sync أو جودة صوت. **مطابقة أصل WAV/الفيديو المقصودة في التعليقات عقد غير مقيس**: الأوامر لم تُنفَّذ على وسائط، والذاكرة تحفظ فرقOrigins لا الأصل المطلق.
- **جولة العرض والرسائل (منفذ — بانتظار مراجعة Codex):** بعد إصلاح B01-F1/F2 صارت `flutter analyze --no-pub` = **No issues found**، `flutter test --no-pub` = **239 ناجحًا** (211 + 28)، `codex_batch01_final_waveform_test.dart` = **2/2 ناجحة** (كانت 1/2)، وملفات القبول السابقة = **12 ناجحة**. سجلات هذه الجولة `OPENCODE_BATCH_01_UI_*_OUTPUT.txt`; تقرير الجولة `docs/reviews/OPENCODE_BATCH_01_UI_CORRECTION_RESULT_AR.md`.
- **مراجعة Codex المستقلة للعرض والرسائل:** أعيد تشغيل239 اختبارًا بنجاح وanalyze نظيف. جميع الملفات الإضافية14 ناجحة (7 قبول أصلية +3 offsets +2 waveform +2 أمثلةSR-08/SR-12 المفتوحة). السجلات الجديدة `CODEX_BATCH_01_UI_{TEST,ANALYZE,ACCEPTANCE}_OUTPUT.txt`. قُبلتF1/F2 وأُغلقت الدفعة الأولى ضمنhost؛ لا اختبار جديد أو تغييرlib من Codex بهذه الجولة.
- **حد اختبار الواجهة:** شجرةEditorScreen كاملة لم تُضخ ولم تُشغّل على جهاز. ثبوتF2 يأتي من البوابة المشتركة ونقطة الرسالة وتطابقها معfailure، واختبارSnackBar صغير، مع فحص أن مسار `_detectSilence` يستدعي هذه النقطة ويعرض ناتجها فعليًا. هذا يكفي لتصحيح الرسالة المحدد ولا يثبت دورة استيراد وتشغيل كاملة.
- **جولة SR-06 (منفذ — بانتظار مراجعة Codex):** بعد إلغاء `minSilenceDuration: 0.3` الثابتة في التمريرة الثانية صارت `flutter analyze --no-pub` = **No issues found**، `flutter test --no-pub` = **267 ناجحًا** (239 + 28)، وملفات القبول المحفوظة كلها = **14 ناجحة**. سجلات هذه الجولة `OPENCODE_SR06_*_OUTPUT.txt`؛ تقرير الجولة `docs/reviews/OPENCODE_SR06_RESULT_AR.md`.
- **مراجعة Codex المستقلة لـSR-06 بتاريخ2026-10-06:** أعيد تشغيل267 اختبارًا بنجاح وanalyze نظيف؛ ملفات القبول السابقة14 ناجحة. قبول جديد `docs/reviews/repro/codex_sr06_acceptance_test.dart` = **2 ناجحة/3 فاشلة**: قبول9.5ms عندmin10ms (المساعد وdatasource)، ورفضtrailing20ms عندmin10ms؛ نجح ضابط الطرح الثنائي عند الحد وpipeline الحقيقي الذي يقبل سكتةخام2s ثم يقلصهاguards إلى1s. السجلات `CODEX_SR06_*_OUTPUT.txt`. SR-06 أعيد لاستكمالR1/R2؛ لا تغييرlib بواسطةCodex.
- **جولة استكمال SR-06 (منفذ — بانتظار مراجعة Codex):** بعد حذف تخفيض 1ms واستبدال شرط 50ms صارت `flutter analyze --no-pub` = **No issues found**، `flutter test --no-pub` = **290 ناجحًا** (267 + 23)، و`test/silence_min_duration_test.dart` = **51 ناجحًا** (كانت 28). **ملف القبول المستقل الجديد `docs/reviews/repro/codex_sr06_acceptance_test.dart` = 5/5 ناجحة** (كانت 2 ناجحة/3 فاشلة)، وكل ملفات القبول المحفوظة = **19 ناجحة** (7 قبول + 3 offsets + 2 waveform + 2 أمثلة SR-08/SR-12 المفتوحة + 5 SR-06). لم يُعدَّل أي ملف في `docs/reviews/repro/` ولا أي توقّع قبول، ولم تُستبدل سجلات Codex ولا `REVIEW_BASELINE.json`. سجلات هذه الجولة `OPENCODE_SR06_REVISION_{ANALYZE,TEST,ACCEPTANCE}_OUTPUT.txt`؛ تقرير التنفيذ `docs/reviews/OPENCODE_SR06_REVISION_RESULT_AR.md`. الملفان المعدَّلان فقط: `lib/features/silence_detector/data/datasources/ffmpeg_silence_datasource.dart` و`test/silence_min_duration_test.dart`. **مرجع waveform ليس دليل قبل/بعد لـSR-06:** `codex_batch01_final_waveform_test.dart` يخصّ حفظ قمم الرسم (B01-F1) وأُعيد تشغيله كحارس عدم انحدار فقط. النتيجة: نفّذت R1/R2 على المصدر؛ الحكم على SR-06 يبقى لـCodex.
- **جولة استكمال دقة الطرح SR06-R3 (منفذ — بانتظار مراجعة Codex):** كان قرار القبول يتغير بنقل السكتة على محور الزمن لأن `numericMarginFor` كانت تحسب الهامش من `min` وحدها بينما المقارنة `end - start`. أُضيف عقد `satisfiesMinimumInterval(start, end, min)` بهامش `numericMarginForInterval` مشتقّ من `kBoundaryRoundingSteps = 4` (ثلاث حدود مقرّبة + تقريب الطرح = `4 * 2^-52 * max(|start|,|end|,|min|)`)، وصارت **كلا** موضعَي الفرض — بعد كل تمريرة وقبل union — تستهلكان `_rejectBelowMinimum` → العقد الجديد. النتيجة: `flutter analyze --no-pub` = **No issues found**، `flutter test --no-pub` = **308 ناجحًا** (290 + 18)، `test/silence_min_duration_test.dart` = **69 ناجحًا** (كانت 51)، `codex_sr06_timestamp_precision_test.dart` = **5/5 ناجحة** (كانت 2 ناجحة/3 فاشلة)، وكل ملفات القبول المحفوظة = **24 ناجحة** (7+3+2+2+5+5). لم يُعدَّل أي ملف في `docs/reviews/repro/` ولا أي توقّع قبول، ولم تُستبدل سجلات Codex ولا `REVIEW_BASELINE.json`. سجلات هذه الجولة `OPENCODE_SR06_PRECISION_{ANALYZE,TEST,ACCEPTANCE}_OUTPUT.txt`؛ تقرير التنفيذ `docs/reviews/OPENCODE_SR06_PRECISION_RESULT_AR.md`. الملفان المعدَّلان فقط: `ffmpeg_silence_datasource.dart` و`silence_min_duration_test.dart`. **حدود مقيسة:** الهامش عند الساعة 3.20e-12s مقابل عجز تمثيل 2.36e-13s (يُقبل)، ويبقى دون عينة 16kHz الواحدة حتى 24 ساعة، وبلوغ عينة واحدة يحتاج طابعًا زمنيًا نحو 2200 سنة؛ الفارق بين القبول والرفض عند min10ms يبقى بثماني رتب (2.4e-13 مقابل 5.0e-4). `satisfiesMinimumSilence(length, min)` بُقيت بلا حدود لملفات قبول Codex، وموثّق أنها فقدت الحدود ولا يجوز استعمالها في الفلترة.
- **لم يُشغّل التطبيق على Android/iOS، ولم يُنفَّذ أي encode بـFFmpeg، ولم يُقَس أي ملف وسائط حقيقي.** نجاح اختبارات نصوص الأوامر أو حسابات الفترات لا شهادة على دقة القص أو على حماية الكلام فعليًا على جهاز.
- **مراجعة Codex لاستكمال SR-06 بتاريخ2026-10-06:** أعيد تشغيل290 اختبارًا بنجاح، وanalyze نظيف، وملفات القبول السابقة19 ناجحة دون تغيير توقعاتها. قبول إضافي `docs/reviews/repro/codex_sr06_timestamp_precision_test.dart` = **2 ناجحة/3 فاشلة**:10ms مقبولة قربالصفر لكنها تُرفض عند `[9.98,9.99]` و`[3600.01,3600.02]` والخلفية المساوية بعدساعة. السبب أن هامشmin لا يراعي دقةstart/end. السجلات الجديدة `CODEX_SR06_REVISION_*_OUTPUT.txt`. قبلR2 واستكمال إزالة1ms؛ بقيR3. لا تغييرlib بواسطةCodex.
- تمت مراجعة البنية والخصائص والمسارات والخدمات الرئيسية على مستوى المشروع، مع تدقيق أعمق لمسار إزالة السكتات وتبعياته. بقية المزايا ليست معتمدة خالية من الأخطاء.
- `PROJECT_MAP.md` سجل تاريخي طويل، و`README.md` كان قالب Flutter عامًا. الذاكرة الحالية والتقرير المؤرخ هما المرجع الأحدث؛ التنفيذ الفعلي يتقدم عليهما عند اختلافه.

## 3. المعمارية

`main.dart` يهيئ Flutter واتجاهات الجهاز ثم يشغل `SilenceRemoverApp`. في `app.dart` يوجد `ProviderScope` واحد أعلى `MaterialApp`، الثيم داكن والمسار الأول شاشة البداية.

تنظيم حسب الميزة مع `presentation/`, `domain/`, `data/`. الفصل ليس كاملًا: شاشات عديدة تنشئ repositories/services مباشرة، وبعض إعدادات الصوت محلية في الشاشة. Riverpod 3 يستخدم `Notifier` و`NotifierProvider`؛ ليست كل الحالة scoped لكل ملف.

النتائج المشتركة في `core/utils/result.dart`: `Success<T>.value` و`AppError<T>.error`، والأخطاء في `core/errors/failures.dart`. بعض المزايا الأخرى ترمي exceptions أو تعيد streams بدل Result؛ اقرأ عقد كل repository.

الخدمات المشتركة:

| المسار | المسؤولية |
|---|---|
| `core/router/app_router.dart` | named routes ونوع arguments؛ cast مباشر، بدون تحقق شامل |
| `core/theme/` | الألوان والثيم الداكن |
| `core/constants/` | حدود sliders، أسماء filters، default adjustments؛ بعض defaults القديمة لا تطابق الكيانات |
| `core/utils/filter_chain_builder.dart` | بناء سلاسل تعديل الصوت والصورة |
| `core/utils/frame_extractor.dart` | استخراج frame للمعاينة |
| `core/utils/file_utils.dart` | دليل التصدير، تنسيق الحجم/الوقت، حذف ملف مساعد |
| `core/utils/media_scanner.dart` | قناة Android لتسجيل الملف في المعرض |
| `silence_detector/domain/services/interval_algebra.dart` | جبر الفترات الخالص: normalize/union/complement/applyProtectedPadding/totalSeconds. لا معامل سماحية فجوة |
| `silence_detector/domain/entities/silence_removal_plan.dart` | خطة الحذف canonical: removals + kept غير قابلة للتعديل + إحصاءات مشتقة |
| `silence_detector/domain/entities/media_timeline.dart` | عقد صفر الفيديو وبداية الصوت؛ فرق بإشارة يُحفظ كما قيس بلا تقصير؛ `detectionWindow()` يعيد تقاطع صريح أو `null` |
| `silence_detector/data/datasources/media_probe_datasource.dart` | FFprobe لمرة واحدة: بداية الفيديو + بداية/مدة الصوت؛ `parseTimestampSeconds` بإشارة و`parseDurationSeconds` بلا إشارة |
| `silence_detector/domain/entities/silence_detection_blocker.dart` | بوابة Reasons واحدة مرتّبة قبل الكشف (مدة → صوت → تقاطع) مع رسالة مستخدم واحدة تستخدمها الشاشة والمستودع |
| `core/services/video_download_service.dart` | HTTP/YouTube، اختيار جودة، تنزيل، دمج، تقدم وإلغاء |
| `core/services/face_detection_service.dart` | ML Kit وتتبع مواضع الوجوه لصنع reframing |
| `core/services/draft_service.dart` | مسودات Shorts بصيغة JSON في documents/drafts |
| `shared/widgets/` | scaffold، loading، permission، error dialogs |

## 4. خريطة الخصائص الفعلية

### استيراد الفيديو والصوت

`video_import/presentation/home_screen.dart` يعرض الاستيراد وبطاقات الأدوات المناسبة للوسيط. يدعم الملفات المحلية والرابط المباشر وYouTube، مع واجهة جودة وتنزيل. الصوت ينتقل إلى محرر الصوت أو Audio Enhancer؛ الفيديو إلى Media Cutter / Silence Remover / Adjuster / Enhancer / Shorts.

`VideoImportRepositoryImpl` يستخدم FilePicker وFFprobe. `VideoFile` يحمل path/name/size/duration/width/height/fps/format/hasAudio. `parseFfprobeDuration` يحول seconds إلى milliseconds بشكل صحيح؛ استخراج FPS الكسري ما زال يأخذ البسط فقط، مثل 30000 بدل 29.97.

### إزالة السكتات من الفيديو

الملفات المحورية: `silence_detector/`، `audio_processing/`، `video_processing/`، `preview/`، `export/`.

**تغيير الدفعة الأولى (2026-10-05) ثم جولة تصحيحها ثم جولة استكمال B01-R1:** أضيفت طبقة فترات canonical وخطة مشتركة، ثم صُحّح أصل الزمن والرسم، ثم رُفع تقصير الإزاحة. التقارير: `OPENCODE_BATCH_01_RESULT_AR.md`، `CODEX_BATCH_01_REVIEW_AR.md`، `OPENCODE_BATCH_01_REVISION_RESULT_AR.md`، `CODEX_BATCH_01_REVISION_REVIEW_AR.md`، `OPENCODE_BATCH_01_FINAL_CORRECTION_RESULT_AR.md`.

المسار الفعلي:

1. `EditorScreen(videoPath)` ينشئ player ثم **يبدأ بـFFprobe**: `MediaProbeDatasource` يقرأ بداية الفيديو (صفر الخط الزمني) وبداية/مدة الصوت، ويعيد `MediaTimeline` بإزاحة **مسنّدة** `audio.start_time - video.start_time` **محفوظة بمقدارها كما قيس، بلا تقصير إلى مدة الفيديو**. fallback هو مدة `VideoPlayerController`، وليس الـwaveform.
2. `AudioProcessorRepositoryImpl.extractAudio` يخرج WAV PCM16 mono 16kHz باسم مؤقت مؤرخ، **بلا** `-copyts` ولا `-start_at_zero`. التحويل **`video = audio + offset`** (تُضاف الإزاحة). تطابق صفرWAV مع بداية stream الصوت **عقد مقصود وغير مقيس**: الأوامر لم تُنفَّذ على وسائط، والذاكرة تحفظ الفرق لا الأصل المطلق. اختيار المسار الصوتي ما زال ضمنيًا (SR-23).
3. `analyzeWaveform` يفك WAV مرة أخرى إلى raw PCM ويجمع حتى 2000 عينة عرض. **الـwaveform للعرض فقط**: فشل لم يعد يمرر duration=0، والمدة المعتمدة من `MediaTimeline`.
4. `FfmpegSilenceDatasource` يشغّل **تمريرة واحدة** بـ`silencedetect` وبحدّ المستخدم نفسه (`noise=…:d=…`). أُزيلت التمريرة الثانية ذات `threshold - 10dB`: هي أخفض threshold (أقل حساسية للصمت) فكل ما تكشفه يقع داخل ما كشفته الأولى، فلم تكن تضيف فاصلًا جديدًا وكانت تضاعف فك الترميز فقط. فلترة الفترات تستخدم `satisfiesMinimumInterval(start,end,min)` بهامش `4 * 2^-52 * max(|start|,|end|,|min|)` يراعي دقة الحدود. الفلترة بعد التمريرة وقبل union تستخدم العقد نفسه. لا تخفيض1ms ولا شرط50ms مستقل للصمت الخلفي؛ تُرفض الحدود غير الصالحة. union يحفظ الفجوات الموجبة. **SR-06 متحقق حسابيًا وعلى قناة محاكاة؛ لا تنفيذ FFmpeg على وسائط حقيقية.**
5. `VadService` اختياري: يقرأ WAV ويفك PCM ويحسب الطاقة داخل `Isolate.run`؛ يقرأ sample rate والقنوات وoffset البيانات من رأس RIFF عبر `wav_pcm_header.dart` بدل 16kHz/44-byte ثابتين، ويشتق زمن الإطار من `frameSamples / sampleRate`. يطرح bursts الكلام من كل سكتة ويحتفظ بالقطع قبلها/بعدها التي لا تقل عن `minSilenceDuration`. `AdaptiveThresholdService` يستخدم العزل والرأس نفسه. لا يوجد نموذج VAD متعلم، والـquantile bug في SR-08 ما زال قائمًا.
6. `SilenceDetectorRepositoryImpl.buildRemovalPlan` يرفض بخطأ مصنّف أي بلا نافذة تقاطع (لا يُختلق أصل بديل)، ثم ينفّذ الترتيب الثابت: normalize → VAD اختياري → **padding داخل السكتة** → Breathing Protection اختياري → normalize → `timeline.audioToVideoTimeline` (إزاحة مسنّدة ثم قصّ) → `SilenceRemovalPlan`. `applyPadding` يحسب `[start+before, end-after]` ويقصّ على المدة ويستبعد `end <= start`؛ حدّ 50ms يُطبّق **فقط عندما يكون أحد الحارسين > 0**، أما الاكتشاف غير المحروس فيبقى كما قرره حد المستخدم (min=10ms لا يُسقط هنا؛ SR-06).
7. `SilenceRemovalPlan` هو المصدر الوحيد للإحصاءات والقص: `removals` و`kept` مطبَّعة وغير قابلة للتعديل (B01-C1)، و`removedSeconds + keptSeconds == totalDurationSeconds`. `silenceRemovalPlanProvider` يحفظه، و`totalSilenceDurationProvider`/`SilenceTimeline` تقرأ منه، واستبعاد عنصر يعيد بناء الخطة كاملة.
8. waveform قابل للتكبير والبحث بالضغط؛ يُرسم على مسطرة الفيديو الحقيقية: `audioDurationSeconds` + `audioStartSeconds` يحدّدان النافذة، وموضع العينة = `audioStart + i/count * span` بزمن الفيديو (اصطلاح الحافة اليسرى مثل `WaveformData.getSampleAtTime`)، وما خارج المسطرة يُتخطى ولا يُقصَّ على حافتها، وتلوين الحذف بزمن أقوى عينة في العمود. **الاختزال يحفظ القمم**: كل عينة توضع في عمود البكسل الذي تقع فيه، وعند تشابه عدة عينات في عمود واحد يفوز **أكبر قيمة مطلقة** — لا خطوة stride تُسقط عينات (B01-F1). القائمة تسمح باستبعاد مقطع من الحذف؛ لا تحرير حدود ولا undo.
9. **سبب عدم الكشف** يأتي من بوابة Reasons واحدة مرتّبة `SilenceDetectionGate` (مدة غير صالحة ← لا مسار صوتي ← تقاطع فارغ) في `editor_screen` و`SilenceDetectorRepositoryImpl` معًا، ونص SnackBar في الشاشة مطابق لنص `SilenceDetectionFailure` (B01-F2). `EditorScreen.detectionBlockedMessage` هي نقطة الدخول التي تستدعيها الشاشة نفسها وتُختبر بها.
10. Preview/Export يشغّلان `ProcessingNotifier.startProcessing` ثم repository ثم `FfmpegCuttingService.cutWithConcat` الذي يقرأ `plan.kept` مباشرة (حُذفت `_buildSpeechSegments`). القص يقرأ الملف الأصلي، فلا يُستخدم `audioPath`. أُعيد بناء القص: تسميات رقمية `[vN]/[aN]` بدل ASCII، والمسار ذو الفترة الوحيدة يقصها فعليًا بـ`-ss/-to` مع إعادة ترميز (stream copy كان يقص على keyframe فقط)، وعند أكثر من 35 مقطعًا بدون Smart Zoom يستخدم **concat demuxer**: ملفات MP4 مؤقتة لكل مقطع ثم `-f concat -safe 0 -i list.txt` مع تنظيف المجلد في `finally`؛ لا يعيد fallback بناء الـfiltergraph نفسه.
11. المعالجة تنتج MP4 مؤقتًا. المعاينة تقارن الأصل بالناتج. التصدير يعيد نسخ video stream وترميز الصوت إلى AAC في MP4/MOV ويحاول تسجيله في معرض Android.

**حكم Codex على جولة العرض والرسائل:** B01-F1 متحقق: التجميع يحفظ القمم وزمن أقوى عينة، وقبولCodex2/2 ناجح. B01-F2 متحقق: بوابة أسباب مرتبة مشتركة ونص واحد مرتبط بمسارSnackBar في الشاشة. شجرةEditorScreen كاملة غير مختبرة؛ تحقق الربط بالمصدر وباختبارنقطة الرسالة وSnackBar صغير. الحكم السابق علىB01-R1 محفوظ. **الدفعة الأولى مغلقة ضمن المصدر/الحساب/host**؛ محاذاةWAV/الفيديو وقياس أداء الجهاز غير مثبتين.

**الوضع بعد اعتماد SR-06 ومراجعة تصحيح B1:** SR-06 معتمدة ضمن المصدر والحساب والمحاكاة السابق. B1 (SR-04/SR-07) متحققة جزئيًا: تحسنت حراسة طلب الكشف، واستُعيدت بوابة الرفض، وأزيل fallback من استبعاد الفترة وprobe الثاني عند تمرير timeline. بقيت هوية إكمال المعالجة، وتداخل Auto مع Smart Zoom والكشف، وعزل العرض بين الجلسات. 317 اختبارًا و34 حالة قبول سابقة ناجحة؛ قبول جديد 1 ناجح/6 فاشلة. لا إغلاق لـSR-12/13/14/18 أو بقية البنود المفتوحة، ولا تحقق وسائط أو جهاز. **بعد دفعة 2026-10-27:** 349 اختبارًا وanalyze نظيف، دون تغيير هذه الأحكام أو حالة B1.


**B1 — الواقع بعد مراجعة Codex لتصحيح R1..R5:** `EditorDetectionController` يملك هوية الجلسة ونسخ الطلب والإعدادات والخطة. `detect` يرفض نتيجة الطلب القديم، وينهي الطلب الذي تغيرت إعداداته، ويستخدم `SilenceDetectionGate`. Auto قابلة للحقن ومحروسة ضد الإغلاق وتغيير إعدادات الكشف، لكنها تعيد Smart Zoom من snapshot قديمة، وتستعيد status محفوظة بعد تغير عملية كشف أخرى. `markRendered` ترفض الجلسة المغلقة والخطة stale، ونجاح الكشف وkeep يبطلان الناتج؛ لكنها لا تستقبل هوية بدء المعالجة، فتسجل ناتجًا قديمًا بإصدار الوصفة الحالية. الشاشة تستدعيها بعد المعالجة العامة وتنتقل دون حراسة إكمال كاملة. `load` يستخدم timeline المحسومة دون probe ثانٍ؛ إنشاء المتحكم ما زال بعد التهيئة. `_syncFromController` يكتب providers عامة، وSilenceTimeline تقرأ الخطة العامة حتى مع متحكم محلي؛ أزيل fallback من التعديل فقط. معالجة الشاشة لا تستخدم ProcessingService المحقونة، وExportScreen تقرأ outputPath العام. تفاصيل R1/R3/R4 في التقرير الحالي؛ لا اعتماد شامل لـSR-04/SR-07.
الإعدادات الفعلية من DetectionParams.defaults():

| الخاصية | default | مجال الواجهة |
|---|---:|---:|
| threshold | -40dB | -110 إلى -10 |
| min silence | 0.25s | 0.01 إلى 5s |
| speech guard before/after | 0/0s | 0 إلى 0.5s |
| VAD / breathing | كلاهما true | on/off |
| Smart Zoom | false؛ amount 1.05 | 1.01 إلى 1.20 عند تفعيله |

`minSilenceDuration` حد اكتشاف السكتة الخام، لا حد أدنى للحذف بعدguards/breathing. يُمرر في أمر التمريرة الوحيدة كما اختاره المستخدم. **عقد المقارنة بعد R3:** `satisfiesMinimumInterval(start, end, min)` بهامش مشتقّ من حدود الفترة نفسها (`4 * 2^-52 * max(|start|,|end|,|min|)`)، فيبقى الحكم مستقلًا عن موضع الفترة على محور الزمن؛ الحدّ غير موجب أو غير finite يُعامَل كصفر، والطول أو الحدود غير finite تُرفض. `satisfiesMinimumSilence(length, min)` بقيت **بلا حدود** لملفات القبول وموثّق أنها فقدت الحدود فلا يجوز استعمالها في الفلترة. الصمت الخلفي بلا حد50ms مستقل ويسلك العقد نفسه.

**دلالات speech guard بعد الإصلاح:** الحقلان `paddingBefore`/`paddingAfter` ينكمشان من **داخل** كل سكتة مؤكدة، `[start+before, end-after]`؛ رفعهما يقلّل الحذف ولا يوسّعه، والفاصل الذي يبتلعه الحارسان يختفي بدل أن يتحول إلى مدى صفري. الواجهة سُمّيت «Speech Guard Before/After» مع شرح صريح. زر Auto يعدّل threshold فقط ولا يعيد الكشف (SR-07). التقرير `docs/reviews/SILENCE_REMOVAL_REVIEW_AR.md` يحتوي بقية العيوب وخطة علاجها.

### Media Cutter — الفيديو

`media_cutter/presentation/screens/media_cutter_screen.dart` و`FfmpegMediaCutterService`: keep selection، remove selection، split عند نقاط يضعها المستخدم، حذف عدة ranges، waveform ونقاط قص ومعاينات حول مواضع الحذف، اختيار مسار سريع stream-copy أو re-encode/fallback. يدعم فيديو بدون audio. الخدمة تحتوي validation للمدى، توليد أوامر مستقل قابل للاختبار، متابعة session وإلغاء وتنظيف الأجزاء المؤقتة. لا تخلطها مع `FfmpegCuttingService` الخاص بالسكتات؛ الأولى أوسع وأحدث، لكن ليست مثبتة سليمة بكل حالات الوسائط.

### Audio Editor

عند `isAudio=true` في route `/media-cutter` يُفتح `AudioEditorScreen` بدل MediaCutterScreen. `ProfessionalAudioEditorService` يدعم MP3/WAV/AAC/M4A، قص/split بنسخ stream، حذف اختيار، كشف صمت واقتراح smart cut centers، noise reduction وvoice enhancement. التشغيل بـjust_audio، الرسم بـaudio_waveforms، تحديد/تكبير/seek، undo/redo، تصدير أجزاء. اكتشاف الصمت هنا مستقل عن silence_detector للفيديو؛ إصلاح أحدهما لا يصلح الآخر تلقائيًا.

### Audio Enhancer

`audio_enhancement/presentation/screens/audio_enhancement_screen.dart` مع `AutoNoiseDetector` و`AudioEnhancementFilterBuilder` و`AudioPreviewCommandBuilder`. الإعدادات: noise floor، gate، de-ess عبر EQ، bass/mid/presence/treble، volume، presets ومعاينة أصل/محسن. السلسلة الحالية: highpass 80Hz → compand gate → lowpass اختياري → EQ → volume → limiter. ليست شبكة إزالة ضوضاء عصبية. معاينة M4A/AAC stereo 48kHz مع `-map 0:a:0` وفحص FFprobe.

### Video Adjuster

`video_adjustment/`: settings مركبة وwidgets بحسب المجموعة؛ brightness/contrast/saturation/exposure/gamma/hue/sharpness/blur؛ shadows/highlights/whites/blacks/midtones؛ temperature/tint/RGB/vibrance/fade؛ crop/rotate/flip/scale/speed/reverse/video fades؛ vignette/noise/denoise/lens distortion؛ LUT/presets؛ volume/noise reduction/normalize/fades/bass/treble/compressor/mute/pitch.

Providers: `adjustmentProvider`, `previewProvider`, `exportProvider`, `undoRedoProvider`. undo محدود بـ20 خطوة مع coalescing 500ms. المعاينة frame وصورة before/after وليست بالضرورة playback لكل filter. التصدير يمر عبر repository و`FfmpegAdjustmentDatasource` وfilter builder. راجع normalization والتعامل مع الملفات بلا audio عند تعديل هذا المسار.

### Video Enhancer

`video_enhancement/` يعمل state machine داخل `EnhancementHomeScreen`: import → analysis → plan → preview → processing → result. `VideoAnalyzerDatasource` يستخرج metadata ومقاييس جودة؛ `EnhancementPlan` يقترح actions؛ `EnhancementSettings` يحمل switches وtarget dimensions وCRF/preset.

المستويات: fast/balanced/quality/ultra؛ CRF 20/18/16/14 وpreset fast/medium/slow/veryslow. Command builder يستخدم hqdn3d، deblock، lanczos scale مع الحفاظ على aspect ratio وpad، curves/eq، unsharp، deband، yuv420p؛ والصوت filters عند التفعيل. لا تفترض أن كلمات stabilize/FPS في الخريطة القديمة تعني وجودها في كل مسار فعلي. هناك direct command ومسار تحليل؛ افحص أيهما يستدعي provider قبل التغيير.

### Shorts Creator

`shorts_generator/`: إعدادات → تحليل → suggestions قابلة للتعديل/الاختيار → تصدير متعدد.

- Cutting modes: interval، smartAudio، scene، manual، ai. وضع ai يجمع scene/audio scoring بقواعد محلية وليس فهمًا لغويًا للمحتوى.
- Platforms: TikTok/Reels/Shorts/Instagram feed/custom؛ output غالبًا 1080×1920، feed 1080×1080.
- Durations: 15/30/60/90s، 3/5/10/15m، custom يعيد 60s في getter الحالي.
- Reframe: centerCrop، pillarbox، faceAware، blurBackground، cinematicLetterbox، kenBurns، shadowGlow، mirrorSplit.
- Quality enum مستقل: low/medium/high/veryHigh/ultra بحدود 4/8/12/20/30 Mbps. **مختلف** عن core ExportQuality الخاص بالسكتات.
- `ShortsProject` يحتوي source/settings/scenes/suggestions. `shortsUiProvider` و`exportSettingsProvider` يديران الحالة، وDraftService يخزن JSON محليًا.
- اكتشاف الصمت لهذا القسم مستقل أيضًا: إعداد ثابت -26dB و0.8s في repository.

## 5. جدول التنقل

| route | arguments / الهدف |
|---|---|
| `/` | splash |
| `/home` | home |
| `/editor` | String videoPath |
| `/processing` | الحالة العامة للمعالجة؛ المسار الرئيسي للسكتات يستخدم dialogs |
| `/preview` | map: originalPath, processedPath, removedDuration, originalDuration |
| `/export` | map اختياري videoPath؛ يفضّل outputPath العام حاليًا |
| `/adjustments` | String videoPath |
| `/shorts` | String videoPath |
| `/shorts/suggestions`, `/shorts/export` | providers تحمل المشروع |
| `/enhancement` | String videoPath |
| `/audio-enhance` | String audioPath |
| `/media-cutter` | map: mediaPath, isAudio, hasAudio, duration |

## 6. الاعتمادات والملفات والمنصات

النسخ التالية قيود `pubspec.yaml`؛ حلّ النسخ الدقيق مرجعه `pubspec.lock`:

| المجموعة | الحزم |
|---|---|
| State / equality | flutter_riverpod ^3.3.1، equatable ^2.0.7 |
| Native media | ffmpeg_kit_flutter_new ^4.1.0، video_player ^2.11.1، chewie ^1.12.0 |
| Audio | just_audio ^0.10.5، audio_waveforms ^2.0.2 |
| Files / permissions | file_picker ^11.0.2، path_provider ^2.1.5، path ^1.9.1، permission_handler ^11.3.1، gal ^2.3.2 |
| Analysis / network | google_mlkit_face_detection ^0.13.2، youtube_explode_dart ^2.3.4 |
| Other | shared_preferences، flutter_animate، shimmer، intl، uuid، cupertino_icons |
| Tests | flutter_test، flutter_lints ^6.0.0 |

لا توجد `vosk_flutter` أو feature `subtitle_generation` في المصدر الحالي رغم ذكرها في PROJECT_MAP. shared_preferences معلنة لكن لم يظهر استعمالها في `lib/` عند الفحص.

تصدير السكتات: Android يحاول `/storage/emulated/0/Download/Ai_video_editing` عند منح permission، ثم fallback إلى application documents. الأنظمة الأخرى تحاول downloads ثم documents. نص الواجهة يقول Downloads حتى مع fallback؛ لا تعتبر الملف ظاهرًا في المعرض لمجرد نجاح FFmpeg. قناة Android: `com.example.ai_video_editing/media_scanner` في `MainActivity.kt`.

المسودات: documents/drafts، ملفات JSON تربط path source ولا تحفظ نسخة مضمونة منه. ملفات التنزيل تبقى في documents. استخراج WAV وprocessed output للسكتات في temporary directory، ولا يوجد تنظيف كامل لدورة حياتهما في EditorScreen.

Android يستخدم Java/Kotlin target 17، SDK versions موروثة من Flutter، applicationId تجريبي `com.example.ai_video_editing` وتوقيع release بمفتاح debug. INTERNET موجود في debug/profile فقط في manifests المفحوصة. iOS deployment target في المشروع 13.0؛ توافق الإضافات/الإذن/بناء release لم يُختبر.

## 7. قواعد التنفيذ التي يجب الحفاظ عليها

1. المصدر الأصلي immutable؛ output لكل job منفصل. خط زمني canonical واحد لكل فيديو وaudio stream مختار صراحة.
2. إزالة السكتات تعمل على فترات **محذوفة**، فلا تعكس معنى padding أو breathing باستعمال كلمة keep بصورة ملتبسة. بعد الدفعة الأولى: `paddingBefore/After` = مساحة محمية داخل السكتة، وتوسيع الحذف خارج الصمت المؤكد غير معروض كإعداد.
3. normalize/validate قبل كل قص: finite، start≥0، end≤duration، start<end، sort، union للتداخل/التماس **الحقيقي فقط**، ثم complement. لا تدمج كلامًا لأن مدته أقل من min silence. **بعد التصحيح:** لا معامل سماحية فجوة في `IntervalAlgebra` إطلاقًا؛ أي فجوة موجبة محتوى محفوظ مهما صغرت.
4. استخدم float seconds داخل filtergraph وmilliseconds مع Duration/statistics. FFprobe duration تُقرأ كثوانٍ نصية. `start_time` رقم بإشارة (`parseTimestampSeconds`)، والمدد فقط تُرفض عند السالب (`parseDurationSeconds`). لا تغيّر الإزاحة finite بسبب طول الفيديو؛ حافظ على الأصل ثم clip للفترات/التقاطع. هذا العقد متحقق حسابيًا في المصنع الحالي بعد الاستكمال.
5. لا تعتمد نجاح تحليل waveform لامتلاك مدة الفيديو. المعاينة والتصدير مرتبطان بنفس job/settings/segments/version؛ invalidation عند تغيير أي منها. **بعد الدفعة الأولى:** المدة من `MediaTimeline` المجرَّبة، والإحصاء والقص يقرآن `SilenceRemovalPlan` نفسها. **بعد التصحيح:** نفس المخطط الزمني يحكم الرسم أيضًا، عبر مدّة نافذة الصوت وإزاحتها المسنّدة.
6. لا تعتمد global FFmpeg callbacks أو global cancel لمهام متزامنة. callback/session/cancel token ودورة تنظيف تخص كل job.
7. افصل pure command builders وخوارزميات الفترات عن plugins لتسهيل الاختبار. `SilenceDetectorRepositoryImpl` يقبل حقن datasource/VAD/breathing؛ `IntervalAlgebra` نقية. `MediaProbeDatasource` ليست نقية: تستدعي plugin؛ `parseTimestampSeconds`/`parseDurationSeconds` وحدهما نقيسان، واختبار probe يحتاج محاكاة القناة أو جهازًا. presentation ما زالت تنشئ implementations مباشرة.
8. لا تُطلق وصف lossless/original/perfect sync على encode غير مقاس. واجهة السكتات تغير AAC bitrate فقط عبر quality؛ concat يعيد ترميز الفيديو.
9. اختبارات native مطلوبة للقص خارج keyframes، A/V offsets، VFR، portrait/SAR، codecs المتعددة وملفات طويلة. نتائج command strings لا تكفي. **مطلوبة أيضًا للدفعة الأولى:** قياس فعلي على جهاز للتأكد من أن speech guard لا يقطع أطراف الكلمات العربية وأن removal plan يطابق ما رآه المستخدم.
10. **حدّ 50ms في `applyPadding` حدّ حارس لا حدّ اكتشاف:** لا يُطبّق على اكتشاف غير محروس، وإلا أبطل حد المستخدم (SR-06). والتمريرة الواحدة في الـdatasource كافية لأن التمريرة الثانية ذات threshold الأدنى كانت subset منها.

## 8. حالة المراجعة وخطة التعاون

التقرير الرئيسي: `docs/reviews/SILENCE_REMOVAL_REVIEW_AR.md`؛ handoff: `docs/reviews/OPENCODE_HANDOFF_AR.md`؛ بقية المشروع: `docs/reviews/PROJECT_REVIEW_AR.md`؛ تنفيذ الدفعة الأولى: `docs/reviews/OPENCODE_BATCH_01_RESULT_AR.md`؛ مراجعتا Codex: `CODEX_BATCH_01_REVIEW_AR.md` و`CODEX_BATCH_01_REVISION_REVIEW_AR.md`؛ طلبا التصحيح: `OPENCODE_BATCH_01_REVISION_REQUEST_AR.md` و`OPENCODE_BATCH_01_FINAL_CORRECTION_REQUEST_AR.md`؛ تقريرا التصحيح: `OPENCODE_BATCH_01_REVISION_RESULT_AR.md` و`OPENCODE_BATCH_01_FINAL_CORRECTION_RESULT_AR.md`.

دور المراجع: إثبات المشكلة → تحديد السبب والاختبار → مراجعة إصلاح OpenCode → تسجيل verified/fixed فقط بالأدلة. في جولة 2026-10-05 الأولى لم تُطبّق إصلاحات إنتاجية، وأضيف توثيق وأمثلة إعادة إنتاج فقط.

### حالة مشاكل إزالة السكتات

| الحالة | المشاكل | ملاحظة |
|---|---|---|
| **تم التحقق — حسابي ومصدر فقط** | SR-01, SR-02, SR-03, SR-19 | union بلا فجوة، guard داخلي، خطة مشتركة ثابتة وmax(end)؛ لا تحقق native |
| **تم التحقق — مصدر وhost؛ ربط F2 مستعاد في B1** | B01-F1, B01-F2 | حفظ القمم صحيح ضمن النطاق السابق؛ controller.detect يستخدم الآن SilenceDetectionGate؛ R5 متحقق، دون تشغيل الشاشة كاملة أو جهاز |
| **تم التحقق — حسابي/host؛ يحتاج قياس وسائط** | SR-05 / B01-R1 | الحكم السابق محفوظ: عيب الإزاحة متحقق الإصلاح، offsets 3/3 والقبول 7/7 |
| **تم التحقق — مصدر وحساب وقناة محاكاة على host** | SR-06 / SR06-R1/R2/R3 | حد المستخدم في الأمر المنفَّذ (كان في التمريرتين وقت الاعتماد؛ صارت تمريرة واحدة في 2026-10-27)؛ مقارنة تراعي حدود الفترة؛ خلفية بلا حد50ms؛308 اختبارات و24 حالة إضافية ناجحة بتأكيد2026-10-22. لا قياس وسائط أو جهاز |
| **متحقق جزئيًا — أعيد للاستكمال R1/R3/R4** | SR-04, SR-07 | R5 مستعاد؛ تحسنت حراسة الكشف ورفض fallback وprobe المكرر. بقيت هوية render وتداخل Auto وعزل العرض.317 اختبارًا و34 حالة سابقة ناجحة؛ قبول جديد 1 ناجح/6 فاشلة |
| Open | SR-08..SR-18, SR-20..SR-24 | محفوظة؛ بما فيهاSR-09 وSR-12/13/14/18. لا إغلاق تلقائي بسببB1 أو دفعة 2026-10-27 |
| **منفذ — بانتظار مراجعة Codex (2026-10-27)** | دفعة الحشو/القص/VAD | لا تغيّر حالة SR المفتوحة. 349 اختبارًا وanalyze نظيف؛ 23/24 حالة repro، والفشل الوحيد توقّع قديم لعدد التمريرتين. لا وسائط أو جهاز |

**الدفعة الأولى وSR-06 معتمدتان ضمن نطاقهما السابق**. B1 (SR-04/SR-07) متحققة جزئيًا وأعيدت لاستكمال R1/R3/R4؛ التقرير `docs/reviews/CODEX_BATCH_B1_REVISION_REVIEW_AR.md` والطلب الحالي `docs/reviews/OPENCODE_BATCH_B1_COMPLETION_REQUEST_AR.md`. لا B2 قبل الاعتماد. القياسات الأصلية وبقية البنود المفتوحة محفوظة.
**خطة تحققSR-16:** في مرحلة الأداء/الجهاز، قس الرسم والتخصيصات وسلاسة التكبير/البحث أثناء التشغيل على2000 عينة وأقصىzoom وأعداد مناطق حذف متزايدة، وسجل الجهاز والملف والقياسات. ليست جدولة آلية. زيادة أعمدة الرسم مع التكبير مناسبة لتوسعة المسطرة؛ لا تضيف معلومات صوتية تتجاوز عينات المصدر.

عند بدء جلسة لاحقة: اقرأ هذه الذاكرة، ثم التقرير الخاص بالمهمة؛ افحص تغيرات المصدر مقارنة بالـbaseline؛ لا تعيد افتراض أن عدد اختبارات المشروع كافٍ للسكتات، ولا تسجّل المخاطر غير المختبرة كأخطاء runtime مؤكدة.

عند بدء **مراجعة** لاحقة: افصل بين «منفذ — بانتظار المراجعة» و«تم التحقق». لا ترفع حالة أي SR إلا بعد فحص المصدر والأدلة المستقلة، مع ذكر نطاق التحقق ونقص التحقق الأصلي. نجاح اختبار القبول على محاكاة plugin ليس تحققًا أصليًا.

## 9. تحديث الذاكرة

بعد كل تعديل: حدّث التاريخ وخصائص الميزة والمسارات المتغيرة، أضف نتيجة الأوامر الفعلية وحدود التحقق، ثم حدّث صف المشكلة في التقرير دون حذف وصفها الأصلي. إذا تغيّرت البنية جذريًا أعد توليد SOURCE_INVENTORY عبر `python tools/review_inventory.py`؛ لا تستبدل baseline المراجعة القديمة لتغطية تغيرات غير موثقة.

### بروتوكول إلزامي قبل كل مراجعة وبعدها

طلب المستخدم صراحةً بتاريخ2026-10-05:

1. قبل **كل مراجعة**، بما فيها مراجعة إصلاحات OpenCode، اقرأ هذا الملف من القرص مجددًا؛ لا تعتمد نسخة من محادثة سابقة.
2. اقرأ تقرير الميزة ثم افحص الكود الحالي والتغييرات الفعلية. إذا اختلف الكود مع الذاكرة، وثّق الاختلاف وصحح وصف الواقع بناءً على الدليل.
3. بعد **كل مراجعة** حدّث الذاكرة حتى إن لم يتغير كود التطبيق: التاريخ، المراجع، النطاق، النتائج وحالة المشاكل، الاختبارات المنفذة فعلًا، حدود التحقق، والخطوة التالية.
4. OpenCode ينفذ دفعة محددة ويوثق تغييراتها ونتائج اختباراته بحالة **«منفذ — بانتظار المراجعة»**. Codex يراجع المصدر والأدلة بصورة مستقلة قبل تسجيل **«تم التحقق»** مع تحديد نطاق التحقق. النجاح الوحدوي لا يعني تحققًا أصليًا على جهاز.
5. حدّث أقسام الخصائص والمسارات عند تغيرها، واحتفظ بمعرفات المشاكل وتاريخها. أخبر المستخدم في نهاية المراجعة بما تم تحديثه في الذاكرة وما بقي مفتوحًا.

## 10. سجل المتابعة

### 2026-10-27 — OpenCode — دفعة الحشو والقص والـVAD — منفذ، بانتظار مراجعة Codex

- **النطاق:** طلب المستخدم الحالي على مساري `silence_detector` و`video_processing` فقط. لم تبدأ B2، ولم تُغلق أي مشكلة مفتوحة، ولم تُعدَّل ملفات `docs/reviews/repro/` أو `REVIEW_BASELINE.json`، ولا يوجد Git diff متاح.
- **الملفات الإنتاجية المعدَّلة:** `silence_detector_repository_impl.dart` (حشو داخلي + حد 50ms مشروط)، `ffmpeg_cutting_service.dart` (إعادة بناء القص)، `vad_service.dart` (عزل + sample rate + طرح الكلام)، `adaptive_threshold_service.dart` (عزل + رأس WAV)، `breathing_protection_service.dart` (دلالات ذيل النفس)، `ffmpeg_silence_datasource.dart` (تمريرة واحدة). ملف جديد: `silence_detector/data/services/wav_pcm_header.dart`.
- **سبب الحشو المعاكس وإصلاحه:** الصيغة القديمة كانت توسّع الحذف خارج السكتة. `applyPadding` صار `[start+before, end-after]` مع قصّ على المدة واستبعاد `end <= start`. **قرار سياسة معلن:** حدّ 50ms يُطبّق فقط عندما يكون `paddingBefore > 0 || paddingAfter > 0`؛ الاكتشاف غير المحروس يبقى خاضعًا لحد المستخدم في الـdatasource، وإلا لأبطل حد 10ms الذي اعتمده Codex في SR-06. أُضيف هامش تمثيل 1ns لمقارنة 50ms فقط، لا لتوسيع أي سياسة وسائط.
- **سبب القص وإصلاحه:** التسميات كانت ASCII (`a+i`) فتنكسر عند 26+ مقطعًا؛ صارت `[vN]/[aN]`. المسار ذو الفترة الوحيدة كان ينسخ الملف كاملًا؛ صار يقص `-ss/-to` ويعيد ترميز الفيديو لأن stream copy يقص على keyframe فقط. عند أكثر من 35 مقطعًا وSmart Zoom غير فعّال يتحول تلقائيًا إلى concat demuxer: استخراج كل مقطع إلى MP4 مؤقت بنفس إعدادات الترميز و`setsar=1`، ثم `-f concat -safe 0 -i list.txt`، مع حذف المجلد المؤقت في `finally`. أُزيل fallback الذي كان يعيد بناء الـfiltergraph نفسه.
- **سبب VAD/العتبة وإصلاحهما:** فك WAV وحساب الطاقة كانا على isolate الواجهة؛ نُقلا إلى `Isolate.run` في الخدمتين. أُضيف `parseWavPcmHeader` لقراءة sample rate/channels/data offset من RIFF (بايت 24..27 وfallback `AppConstants.audioSampleRate`) بدل 16kHz و44 بايت ثابتين. زمن إطار VAD صار `frameSamples / sampleRate` لا 20ms ثابتة، فمعدلات مثل 11025Hz لا تنزلق. VAD صار يطرح bursts الكلام من السكتة ويحتفظ بالقطع قبل/بعد التي تحقق `minSilenceDuration` بدل حذف السكتة كاملة.
- **التمريرة الواحدة:** أزيلت تمريرة `silencedetect` الثانية ذات `threshold - 10dB`. هي أخفض threshold (أقل حساسية للصمت) فكل ما تكشفه يقع داخل نطاق الأولى، وكانت تضاعف فك الترميز. بقي حد المستخدم في الأمر الوحيد وبلا `d=0.3`.
- **Breathing Protection:** تُتخطى المدد <150ms، وتبقى 150–250ms كاملة، والمدد الأطول تحتفظ بذيل 100ms قبل الكلام مع حد بقاء 150ms؛ لا "نصف أول" ولا توسيع/دمج.
- **الاختبارات:** جديدة `test/silence_padding_test.dart`, `test/wav_pcm_header_test.dart`, `test/vad_service_test.dart` (يشمل 11025Hz وإطارًا كسريًا), `test/ffmpeg_cutting_command_test.dart`. معدَّلة `test/silence_min_duration_test.dart` (تمريرة واحدة) و`test/silence_detection_pipeline_test.dart` (إجمالي breathing الصحيح 1.3s مع بقاء دلالاته).
- **الفحوص الفعلية:** `flutter analyze --no-pub` = **No issues found**؛ `flutter test --no-pub --reporter compact` = **349 ناجحًا**؛ ملفات repro الستة (batch01 + offsets + waveform + sr06 acceptance + sr06 timestamp + characterization) = **23 ناجحًا/1 فاشل**. الفشل الوحيد: `codex_sr06_acceptance_test.dart` يتوقع `commands.length == 2`، وقد أزيلت التمريرة الثانية بمطلب المستخدم؛ توقّع `plan.removals` نفسه نجح. لم يُعدَّل ملف القبول. `silence_characterization_test.dart` = 2/2 كما كان (SR-08 quantile وSR-12 ما زالتا مفتوحتين).
- **تحديث التوثيق:** أُعيد توليد `docs/SOURCE_INVENTORY.md` = **158 ملفًا و29789 سطرًا**. حُدِّثت مقدمة الذاكرة والأقسام 1/2/4/7/8/10، مع الحفاظ على معرفات SR وسجلات 2026-10-22 وما قبلها.
- **حدود التحقق:** لا Android/iOS، لا build، لا تنفيذ FFmpeg/FFprobe، لا `silencedetect` على وسائط، لا encode، لا قياس A/V أو جودة صوت أو أداء ذاكرة العزل. لم يُختبر concat demuxer فعليًا ولا مانيفست مسارات Windows ولا AAC priming عند `-c copy`. نجاح الأوامر والحسابات على host لا يثبت دقة القص أو حماية الكلام. SR-08/SR-12 وما تبقى من B1 (R1/R3/R4) مفتوحة.
- **التالي:** يقرأ Codex هذه الذاكرة من القرص ويراجع المصدر والأدلة. يُتوقع اعتبار فشل `hasLength(2)` توقّعًا قديمًا أبطله مطلب التمريرة الواحدة، لا انحدارًا، دون تعديل ملف القبول. لا تبدأ B2 قبل الاعتماد.

### 2026-10-22 — Codex — مراجعة تصحيح B1-R1..R5

- قُرئت الذاكرة من القرص قبل المراجعة وفُحص المصدر والتقرير والأدلة. النتائج المستقلة: 317 اختبارًا ناجحًا، analyze نظيف، 34 حالة قبول سابقة ناجحة. قبول إضافي من 7 حالات: 1 ناجح/6 فاشلة؛ خدمات محكومة الإكمال على المتحكم وSilenceTimeline الفعليين.
- الحكم: R5 متحقق، وأزيل fallback من الاستبعاد وprobe الثاني في المسار المختبر؛ اختلاف paramsVersion ينهي طلب الكشف المهمل دون إيقاف طلب أحدث. بقيت R1/R3/R4: ناتج قديم يُنسب لوصفة جديدة، Auto تعيد Smart Zoom قديمًا أو status غير صحيحة عند تداخل الكشف، وعرض خطة عامة تخص جلسة أخرى. SR-04/SR-07 متحققتان جزئيًا؛ لا B2.
- التقرير `CODEX_BATCH_B1_REVISION_REVIEW_AR.md` والطلب التالي `OPENCODE_BATCH_B1_COMPLETION_REQUEST_AR.md`. الاختبار `repro/codex_batch_b1_revision_acceptance_test.dart` والسجلات `CODEX_BATCH_B1_REVISION_*_OUTPUT.txt`. لا تغيير إنتاجي من Codex ولا استبدال للأدلة القديمة. لا تشغيل كامل للشاشة أو build أو جهاز أو FFmpeg أو وسائط أو قياس A/V.
- الذاكرة: المقدمة والأقسام 2/4/8/9/10 محدثة. نُقل سجل OpenCode من وسط بروتوكول القسم 9 إلى سجل المتابعة، وصُحح نصه ومحارف escape مع حفظ وقائع التسليم وتقريره وسجلاته الأصلية. صُححت دعوى أن جميع mismatches تعيد idle: اختلاف requestId لا يغير حالة الأحدث.
- التالي: OpenCode يقرأ الذاكرة وينفذ الاستكمال المحدد فقط، ويضيف regressions ويحدث الذاكرة بحالة «منفذ — بانتظار مراجعة Codex». سيقرأ Codex الذاكرة مجددًا قبل المراجعة التالية ويحدثها بعدها. اعتماد الدفعة الأولى وSR-06 محفوظ؛ لا إغلاق لبقية المسائل المفتوحة.

### 2026-10-22 — OpenCode — B1 تصحيحات R1..R5 — سجل تسليم تاريخي مصحح نصيًا

- نطاق التسليم: `OPENCODE_BATCH_B1_REVISION_REQUEST_AR.md`؛ لم تبدأ B2. أضيفت حراسة closed/planIsValid إلى markRendered وربط استدعائها بإكمال الشاشة، ومسح الناتج عند keep أو نجاح الكشف، وإنهاء الطلب عند اختلاف paramsVersion. أضيف حقن autoThresholdService وحراسة هويتها، وأزيل fallback من keep عند وجود متحكم، وأصبح load يقبل timeline المحسومة، واستُخدمت SilenceDetectionGate في detect.
- نتائج OpenCode المعلنة: 317 اختبارًا و10/10 قبول B1 ناجحة وanalyze نظيف. التقرير `OPENCODE_BATCH_B1_REVISION_RESULT_AR.md` والسجلات `OPENCODE_BATCH_B1_REVISION_{ANALYZE,TEST,ACCEPTANCE}_OUTPUT.txt` محفوظة. حالة التسليم الأصلية «منفذ — بانتظار مراجعة Codex»؛ الحكم المستقل الأحدث أعلاه.
- حدود التسليم: لا جهاز أو build أو FFmpeg أو وسائط؛ EditorScreen كاملة لم تُضخ. المعالجة الفعلية ما زالت في الشاشة؛ لا إغلاق لـSR-12/13/14/18.
- تصحيح التوثيق: كان السجل داخل القسم 9 بين البندين 4 و5 واحتوى محارف escape مشوهة. نُقل وصُحح نصيًا؛ لم يُمس التقرير الأصلي أو السجلات. دعوى التسليم أن كل اختلاف هوية يعيد idle لا تطابق المصدر: اختلاف requestId يرجع دون تغيير حالة الطلب الأحدث، وهو السلوك الصحيح الذي أثبته اختبار Codex.

### 2026-10-22 — Codex — مراجعة B1 المستقلة

- قُرئت الذاكرة من القرص قبل المراجعة. فُحص المتحكم وربط الشاشة والمعالجة والتصدير وwidgets والخدمات واختبارات التسليم. النتائج:317 ناجحًا وanalyze نظيف و24 حالةسابقة ناجحة؛ قبولB1 المستقل10 =1 ناجح/9 فاشلة.
- الحكم: SR-04/SR-07 أعيدتا للتصحيح B1-R1..R5. إنشاءجلسة ورفضإكمالdetect القديم صحيحان جزئيًا، لكنناتجrender بلاهوية مكتملة،Auto يعيدparams قديمة ويشعر بعدdispose،وحالةdetect لا تنتهي بعدإبطالها،والـwidget يتجاوزالحراسةبـfallback،وبوابةالأسبابالمعتمدة لمتعد مستخدمة فيمسارالكشف.
- التقرير `CODEX_BATCH_B1_REVIEW_AR.md` وطلبالتصحيح `OPENCODE_BATCH_B1_REVISION_REQUEST_AR.md`؛ اختبارCodex الجديد يشغلالمتحكم وSilenceTimeline الفعليين. لمتُضخEditorScreen كاملة؛ ملاحظاتالمعالجةوnavigation مدعومةبتتبعالمصدر لاوسائط.
- لا تغييرlib بواسطةCodex؛ اختباروتوثيق فقط. لاbuild/جهاز/FFmpeg/وسائط/قياسA/V أوGitdiff. أحكامSR-06 والفترات محفوظة؛ B1 يجب أن تستعيدربطبوابةF2،ولا إغلاقSR-12/13/14/18.
- الذاكرة:المقدمة والأقسام1/2/4/8/10 حُدثت، وصُحح سجلOpenCode المشوه نصيًا معحفظالتاريخوالنتائجوتقريرالأصل. لااستبداللسجلاتالاختبارات أوbaseline. لاB2؛ OpenCode ينفذالتصحيح ثميسلم بحالةانتظارالمراجعة ويحدثالذاكرة. سيقرأCodex الذاكرة قبلالمراجعة التالية ويحدثها بعدها.

### 2026-10-22 — Codex — تثبيت اعتماد SR-06 وتسليم B1

- قُرئت الذاكرة من القرص قبل استئناف المراجعة، وفُحص المصدر الحالي وعقد دقة الحدود وموضعا الفلترة والتقارير. تقرير اعتماد2026-10-06 كان محفوظًا لكن حالة الذاكرة لم تُحدّث عند توقف الجولة؛ أُكمل التحديث اليوم بعد إعادة التحقق.
- النتائج الفعلية اليوم:308 اختبارات ناجحة، analyze نظيف،24 حالة إضافية ناجحة. سجلات جديدة مؤرخة دون استبدال الأدلة السابقة. لا تغيير lib أو الاختبارات؛ لا build أو جهاز أو FFmpeg أو وسائط حقيقية أو قياس A/V.
- الحكم: اعتماد SR-06 ضمن المصدر والحساب وقناة FFmpegKit المحاكاة، وحفظ قبول الدفعة الأولى. لا ملاحظة مانعة جديدة في نطاقه. لا إغلاق لبقية البنود المفتوحة أو تحقق الوسائط.
- تحديث الذاكرة: المقدمة والأقسام2/4/8/10. سجل OpenCode الذي أُصلح نصيًا في الجولة السابقة محفوظ؛ فُحص عدم وجود محارف تحكم غير متوقعة.
- التالي: OpenCode ينفذ B1 فقط (SR-04/SR-07) وفق `OPENCODE_BATCH_B1_REQUEST_AR.md` ثم يحدّث الذاكرة ويسلم بحالة «منفذ — بانتظار مراجعة Codex». لم يبدأ Codex التنفيذ. المراجعة التالية تبدأ بقراءة الذاكرة وتختتم بتحديثها.


### 2026-10-22 — OpenCode — B1 (SR-04/SR-07) — سجل تسليم تاريخي مصحح نصيًا

- النطاق:OPENCODE_BATCH_B1_REQUEST_AR.md. أضيف EditorDetectionController وواجهات editor_services وربطهما بـEditorScreen والإعدادات والقائمة. لكل متحكمvideoPath/sessionId وطلبكشف ونسخةparams وخطة؛ detect يهملالنتائجالقديمة. الخدمةالفعليةللمعالجةمازالت فيالشاشة، وProcessingService الافتراضيةplaceholder.
- نتائجOpenCode المعلنة:317 اختبارًا ناجحًا وanalyze نظيف؛9 اختباراتمتحكم. تقرير OPENCODE_BATCH_B1_RESULT_AR.md وسجلات OPENCODE_BATCH_B1_*_OUTPUT.txt محفوظة. لمتبدأB2 ولميعلنإغلاقSR-12/13/14/18.
- الحدود:لا جهاز/build/FFmpeg/وسائط. اختباراتهويةالمتحكم دونضخEditorScreen كاملة؛ تهيئةالملف مازالت بالشاشة. الحالةوقتالتسليم:منفذ — بانتظارمراجعةCodex. الحكم الحالي فيسجلCodex أعلاه.
- تصحيح نصي:سجلB1 فيالذاكرة احتوىمحارف VT وأسطرescape فيvideoPath/renderRecipeVersion وأسماءدوال؛ أعيدت صياغته معحفظوقائعالتسليم، ولميُمسالتقريرأوالسجلاتالأصلية.

### 2026-10-06 — OpenCode — استكمال دقة طرح الحدود SR06-R3 — سجل التنفيذ المصحح نصيًا بواسطة Codex

- النطاق: OPENCODE_SR06_PRECISION_REQUEST_AR.md وحده. لم تبدأ دفعة جديدة، وبقيت المسائل الأخرى مفتوحة.
- السبب: numericMarginFor(min) لا يراعي دقة start/end عند حساب end - start؛ السكتة العشرية10ms تغير قرار قبولها حسب موضعها.
- التنفيذ: satisfiesMinimumInterval(start,end,min) بهامش4 * 2^-52 * max(|start|,|end|,|min|). كلا موضعي الفلترة يستخدمان العقد عبر _rejectBelowMinimum. المساعد بلاحدود باقٍ للقبول القديم وموثق أنه غير مناسب لفلترة intervals.
- اختبارات التنفيذ المعلنة:308 ناجحة، analyze نظيف،69 اختبارًا للمدة، و24 حالة إضافية ناجحة؛ timestamp precision5/5. الملفات الإنتاجية/الاختبارية المعلنة اثنان: ffmpeg_silence_datasource.dart وsilence_min_duration_test.dart. تقرير التنفيذ OPENCODE_SR06_PRECISION_RESULT_AR.md وسجلات OPENCODE_SR06_PRECISION_*_OUTPUT.txt.
- الحالات المغطاة المعلنة:10ms عند0.01/9.98/3599.99/3600.01/86400.01؛9.5ms مرفوضة في المواقع نفسها؛ مدد0.01/0.25/2/5 بعدساعة؛ فاصل خلفي وإعادة الفلترة قبلunion والمسار إلىplan. لا تغيير في قبولاتCodex أوbaseline أوالسجلات السابقة.
- حدود التنفيذ: لاbuild/جهاز/FFmpeg/silencedetect/probe/encode/وسائط أوقياسA/V. أرقام الهامش حساباتdouble؛ التفاعل معSlider وEditorScreen كاملين غير مشغّل. نطاق الهامش حتى24ساعة مختبر حسابيًا، ولا يمثل اعتمادًا لأوقات غيرمحدودة.
- الحالة عند تسليمOpenCode: منفذ — بانتظار مراجعةCodex. الحالة الحالية يحددها أحدث سجل مراجعة أعلاه؛ تاريخ التنفيذ محفوظ.
- تصحيح نصي: السجل الأصلي في الذاكرة احتوى محارفNUL وأسماء دوال مشوهة وأسطرescape. أعيدت صياغته دون تغيير النتائج المعلنة؛ تقريرOpenCode وسجلاته الأصلية محفوظة.

### 2026-10-06 — Codex — مراجعة استكمال SR-06 عند الحدود

- قُرئت الذاكرة من القرص قبل المراجعة. فُحص المصنع والمقارنةالهامشية والفلترةبعدالتحليل وقبلunion وإغلاقالفاصل الخلفي و51 اختبارًا للمشكلة وتقريرالتسليم.
- التحقق المستقل:290 اختبارًا ناجحًا، analyze نظيف،19 قبولًا سابقًا ناجحة دون تغييرها. قبول إضافي لـtimestamps =2 ناجحة/3 فاشلة علىdatasource الفعلي؛ قبول10ms قربالصفر، رفضنفسالمدة عند9.98..9.99 و3600.01..3600.02 والخلفيةبعدساعة، ورفض9.5ms بعدساعة صحيح.
- الحكم: R2 متحقق، وإزالة1ms صحيحة، لكن SR-06 أعيد لاستكمالSR06-R3: هامشmin لا يقدر خطأتمثيلstart/end عندطرحها. المطلوب عقددقة للحدود، لا زيادة64 فقط أو العودةلهامشزمني.
- أضيف `repro/codex_sr06_timestamp_precision_test.dart` و`CODEX_SR06_REVISION_REVIEW_AR.md` و`OPENCODE_SR06_PRECISION_REQUEST_AR.md`؛ السجلات `CODEX_SR06_REVISION_*_OUTPUT.txt` جديدة. لا تغييرlib أو قبولاتقديمة أوbaseline/سجلاتسابقة.
- القيود: لاbuild/جهاز/FFmpeg/silencedetect/probe/encode/وسائط أو قياسA/V. تقرير هذهالجولة لا يدعي أنfallback0 السابق خلقصمتًا منNaN فعليًا؛ ما ثبت هو صحةالرفض الحالي. تصحيح تفسيردليلwaveform محفوظ.
- المقدمة والأقسام2/4/8/10 حُدثت بحكمCodex، وتاريخOpenCode محفوظ. التالي: OpenCode يستكملR3 فقط ثم يسلم وينتظرالمراجعة؛ سيقرأCodex الذاكرة قبلها ويحدثها بعدها. لا دفعةجديدة الآن.

### 2026-10-06 — OpenCode — استكمال SR-06 عند الحدود (SR06-R1 + SR06-R2) — منفذ، بانتظار مراجعة Codex

- **النطاق:** `docs/reviews/OPENCODE_SR06_REVISION_REQUEST_AR.md` وحده. لم تُلمس VAD ولا سياسة threshold العامة ولا الرسم ولا اختيار المسار ولا cleanup ولا ملكية الحالة، وبقيت SR-04/07/08/10/11/16/21/22/23 مفتوحة. لم تبدأ دفعة جديدة.
- **SR06-R1 السبب الجذري:** شرط الحدّ كان `length >= min - 0.001` أي تخفيضًا **زمنيًا 1ms**. المقارنة بين مدتين بالثواني تحتاج هامشًا عدديًا؛ و1ms تعادل 16 عينة عند 16kHz، وهي 10% من أصغر حدّ قابل للضبط (10ms)، فكانت تقبل 9.5ms عند min10ms.
- **SR06-R1 التنفيذ:** حُذف `kMinSilenceLengthToleranceSeconds`؛ أضيف `kNumericToleranceUlps = 64` و`_relativeUlp = 2^-52` و`numericMarginFor(min) = min*64*2^-52`، والمقارنة `length >= min - numericMarginFor(min)`. الهامش 1.42e-16s عند min10ms و7.11e-14s عند min5s، أصغر من 1ms بنحو 7.0e12 مرة وأصغر من عينة 16kHz بنحو 4.4e8 مرة. حد غير موجب ⇒ هامش 0 وقبول كل شيء؛ طول غير finite ⇒ رفض.
- **SR06-R2 السبب الجذري:** إغلاق `silence_start` غير المنتهي كان يشترط `fallbackEnd > currentStart + 0.05`، أي سياسة قبول ثانية مستقلة عن حد المستخدم، فتسقط صمتًا خلفيًا 20ms عند min10ms مع أنه أطول من حدّ المستخدم.
- **SR06-R2 التنفيذ:** حُذف الشرط؛ الفاصل يُغلق متى كانت الفترة finite و`start≥0` و`end>start`، ثم يطبّق `_rejectBelowMinimum` حدّ المستخدم نفسه. `finiteOr` صار بـ`fallback: double.nan` بدل `0` حتى لا يختلق حدٌ غير مقروء صمتًا بطول النافذة (SR-03).
- **الاختبارات — `test/silence_min_duration_test.dart` = 51 ناجحًا (كانت 28):** استُبدلت سياسة 1MS باختبارات دقة (رفض `0.0095` عند 0.01 بالمساعد وعبر الـdatasource، رفض `min*0.999` و`min*0.5`، قبول `0.3-0.1` عند 0.2 بالمساعد وعبر الـdatasource، هامش موجب و<1e-12 و<min/1e9 ومتصاعد مع الحد، حدّ صفر/سالب بلا هامش، طول غير finite مرفوض، ضابط 32 وحدة في آخر خانة مقبول و1e-12 نسبيًا مرفوض). وأُضيفت الخلفية **10/20/49/50/51/60/500/1500ms** عند حد 10ms (كلها مقبولة؛ 10/20/49 كانت تسقط)، ونفسها عند حد 100ms (كلها مرفوضة)، 3s عند 2s مقبولة و1.5s عند 2s مرفوضة، فترة صفرية، فترة تنتهي قبل بدايتها، `NaN` كنهاية نافذة، `NaN` كبداية صمت، بداية سالبة `-5`، و`silence_end` المكتمل يسلك فرعًا.
- **الاختبارات المنفذة فعلًا:** `flutter analyze --no-pub` = **No issues found**؛ `flutter test --no-pub` = **290 ناجحًا** (267 + 23)؛ `test/silence_min_duration_test.dart` = 51؛ `codex_sr06_acceptance_test.dart` = **5/5 ناجحة** (كانت 2 ناجحة/3 فاشلة)؛ `codex_batch01_acceptance_test.dart` = 7/7؛ `codex_batch01_revision_offsets_test.dart` = 3/3؛ `codex_batch01_final_waveform_test.dart` = 2/2؛ `silence_characterization_test.dart` = 2/2 (SR-08 وSR-12 المفتوحتان). إجمالي القبول المحفوظ 19. لم يُعدَّل أي ملف في `docs/reviews/repro/` ولا أي توقّع قبول، ولم تُستبدل سجلات Codex ولا `REVIEW_BASELINE.json`. السجلات الجديدة `OPENCODE_SR06_REVISION_{ANALYZE,TEST,ACCEPTANCE}_OUTPUT.txt`.
- **تصحيح تفسير الأدلة:** `codex_batch01_final_waveform_test.dart` يخصّ حفظ قمم الرسم (B01-F1) وليس حدّ المدة؛ لم يتغيّر ولم يُعدَّل، وأُعيد تشغيله كحارس عدم انتدار فقط. الدليل الخاص بـSR-06 هو `codex_sr06_acceptance_test.dart` وملف الاختبار المملوك للمشكلة.
- **ما لم يتغيّر:** حدّ المستخدم في الأمرين وبلا `d=0.3`، فرق threshold 10dB، union بلا سماحية فجوة، وguards/breathing بلا فرض min على طول الحذف النهائي؛ فسكتة خام 2s عند min2s تُقبل ثم يقصّها الحارس إلى 0.5s وتُحذف رغم قصرها عن الحد. لم يتغيّر `test/silence_datasources_test.dart`.
- **الحدود:** لا جهاز ولا Android/iOS ولا build، ولا FFmpeg حقيقي ولا `silencedetect` على وسائط، ولا encode ولا probe ولا ملف وسائط ولا قياس A/V أو جودة صوت. كل النتائج من محاكاة قناة FFmpegKit على host. **لم يُثبت** أن بناء FFmpeg حقيقي يطبع `silence_start` غير المنتهي أو أن `silencedetect` يلتزم بـ`d=` بالضبط على تسجيل عربي؛ «الفاصل الخلفي» افتراض معقول غير مقيس. عقد محاذاة WAV/الفيديو يبقى غير مقيس. اختبار واجهة EditorScreen لم يُضخ.
- **التالي:** Codex يقرأ هذه الذاكرة من القرص ويراجع التنفيذ والأدلة ثم يسجّل حكمه على SR-06. **لا تبدأ أي دفعة جديدة قبل ذلك.** يُنتبه المراجع إلى أن `64 * 2^-52` اختيار محافظ، وأن الاختبار يفعّل الفصل عند 32 وحدة مقابل 1e-12 نسبيًا.

### 2026-10-06 — Codex — مراجعة SR-06 المستقلة

- قُرئت الذاكرة من القرص قبل المراجعة. النطاق: الأمران، helper الحد، فلتر كل تمريرة وقبلunion، إغلاق الصمت الخلفي، موضع الحد بالنسبة للحماية، واختبارات وتسليمOpenCode.
- تحقق267 اختبارًا وanalyze نظيف و14 حالةقبول سابقة ناجحة. قبولمستقل جديد5 =2 ناجحة/3 فاشلة على تنفيذالمشروع الفعلي؛ فشلان لـR1 وحالة لـR2. نجح ضابط الدقةالثنائية وdatasource→repository→plan معguards ضمن مجال الواجهة.
- الحكم: d المستخدم نافذ في الأمرين، لكن قبول9.5ms عندmin10ms ورفضtrailing20ms عندالحد نفسه يمنعان اعتمادSR-06 بالكامل. لا نختار1ms كسماحية عائمة؛ يلزم هامش عددي ضيق معلل وشرطصلاحية للفاصل الخلفي دون حد50ms مستقل.
- أُضيف `docs/reviews/repro/codex_sr06_acceptance_test.dart` وتقرير `CODEX_SR06_REVIEW_AR.md` وطلب `OPENCODE_SR06_REVISION_REQUEST_AR.md`؛ السجلات `CODEX_SR06_*_OUTPUT.txt`. لا تغييرlib أو توقعاتقبول سابقة، ولا استبدالbaseline/سجلاتقديمة.
- لاbuild/جهاز/silencedetect/encode/probe/وسائط أو قياسA/V. المحاكاة تختبر أوامرومنطقhost، وليست إثبات فقدكلام فيتسجيل.
- صُححت مقدمةالذاكرة المكررة وعنوانها وجدولالإعدادات والوصفالحالي وبنودالسجلالمكررة، مع حفظ أحكامالتنفيذ وتواريخه كماوردت. الأقسامالمحدثة: المقدمة و2/4/8/10.
- التالي: OpenCode يستكملR1/R2 فقط ويسلم بحالةانتظارالمراجعة؛ Codex يقرأالذاكرة مجددًا قبلالمراجعة ويحدثها بعدها. لا انتقالللـB بعد.

### 2026-10-05 — OpenCode — جولة SR-06 — منفذ، بانتظار مراجعة Codex

- **النطاق:** `docs/reviews/OPENCODE_SR06_REQUEST_AR.md` وحده. لم تُلمس VAD ولا سياسة threshold ولا الرسم ولا اختيار المسار ولا ملكية الحالة، وبقيت SR-04/07/08/10/11/16/21/22/23 مفتوحة. لم تبدأ الدفعة B.
- **السبب الجذري:** التمريرة الثانية في `FfmpegSilenceDatasource.detectSilence` كانت تبني `DetectionParams` جديدة بـ`minSilenceDuration: 0.3` ثابتة. أي أن اختيار المستخدم كان نافذًا في التمريرة الأولى فقط، فسكتة مؤكدة بطول 0.4s كانت تدخل الحذف عند `min=2s` لأن التمريرة الثانية قبلتها. أُلغي الحدّ الثابت.
- **التنفيذ:** `sensitiveParams` صار `params.copyWith(silenceThreshold: params.silenceThreshold + kSecondPassThresholdOffsetDb)` فيأخذ الحد نفسه مع بقاء تمييز الـthreshold بنحو 10dB. أُضيف `kSecondPassThresholdOffsetDb = -10.0` و`kMinSilenceLengthToleranceSeconds = 0.001` وثابت نقّي `satisfiesMinimumSilence(length, min)`. وفرض الحد مرتين: على نتيجة كل تمريرة بعد التحليل، ومرة أخرى قبل الدمج، ليغطي المحلل والفاصل الخلفي.
- **الحدّ العائم موثّق:** المقارنة شاملة عند الحدّ، مع تسامح 1ms تحته لأن `silencedetect` يطبع ثوانٍ عشرية كنص وقد تعود فاصل على الحدّ ناقصة بعدد قليل من وحدات العائمة. 1ms أصغر بكثير من إطار VAD (20ms) ومن أصغر حدّ قابل للضبط (10ms)، فلا تُدخل صمتًا استبعده المستخدم، بل تمنع ضياع فاصل على الحدّ بسبب ضجيج الأعداد العائمة.
- **ما لم يتغيّر عمدًا:** `minSilenceDuration` حدّ اكتشاف السكتات الخام فقط، ولا يُفرض على الحذف النهائي: اختبار خط الأنابيب يثبت أن سكتة خام 2s عند `min=2s` تُقبل ثم يقصّها Speech Guard بمقدار 0.75s لكل جانب إلى 0.5s — وهي **أقصر من الحد ومع ذلك تُحذف**. الفرض موجود في الـdatasource وحده.
- **اختبار جديد:** `test/silence_min_duration_test.dart` بـ28 اختبارًا. الـmock يقرأ `noise=`/`d=` من **كل أمر منفَّذ** ويردّ بسجل مختلف لكل قيمة `d=` (لا سجل واحد مشترك)، فيتحقق من أمرَي التمريرتين فعليًا. يغطي: min 0.01/0.25/2/5 في الأمرين، سكتات 0.4/0.9/1.99s مرفوضة عند 2s مقابل 2s و2.01s و5s مقبولة، حدّ عائم عند الحدّ وداخل التسامح وخارجه، طول غير finite، حدّ غير موجب، الصمت الخلفي المُركَّب، بقاء الفجوة الموجبة 10ms، union للتداخل والتماس، وخط الأنابيب مع guards.
- **تصحيح اختبار:** `raising minSilenceDuration does not widen the merged result` في `silence_datasources_test.dart` كان يستخدم سكتتين أقصر من الحدّ الجديد فسقطتا؛ غُيّر مثاله إلى سكتتين 2s فوق كل حدّ تحت الاختبار، لأن قصده union لا الحدّ.
- **القيود — لم يُشغَّل:** لا build ولا جهاز، لا `silencedetect` على وسائط حقيقية، لا encode، لا قياس A/V أو جودة صوت. **لم يُثبت بعد** أن silencedetect على بناء حقيقي يحترم `d=` بالضبط، وأن سلّم 0.4s لم يكن قائمًا أصلًا في تسجيل صوتي عربي.
- **التالي:** Codex يقرأ هذه الذاكرة من القرص ويراجع المصدر والأدلة ويحدّث الحالات. **لا تبدأ الدفعة B قبل ذلك.**


### 2026-10-05 — Codex — مراجعة B01-F1/F2 وإغلاق الدفعة الأولى ضمن host

- قُرئت الذاكرة من القرص قبل المراجعة. فُحص تجميع القمم وزمنها والتكبير والإزاحة، والبوابة المشتركة واستهلاكها في الشاشة والمستودع، واختبارات الرسم والأسباب وتقرير التسليم.
- التحقق المستقل: 239 اختبارًا ناجحًا؛ analyze نظيف؛ الحالات الإضافية 14 ناجحة (12 قبول و2 أمثلة مفتوحة). السجلات `CODEX_BATCH_01_UI_*_OUTPUT.txt` جديدة والسجلات السابقة محفوظة.
- الحكم: قبول F1/F2، وإغلاق الدفعة الأولى ضمن المصدر والحساب والرسم على host. لم تظهر ملاحظة مانعة جديدة في نطاق الجولة. SR-01/02/03/19 وحساب SR-05 والبنود B01 متحققة في نطاقها؛ قياس وسائط SR-05 واختيار مسار SR-23 وقياس أداء SR-16 تبقى مفتوحة.
- حد الواجهة: لم تُضخ EditorScreen كاملة؛ فُحص استدعاؤها لنقطة الرسالة المشتركة، واختُبر تطابق النصوص وSnackBar صغير. هذا مناسب لتصحيح الرسالة ولا يثبت تشغيل المحرر كاملًا.
- التغيير بواسطة Codex: تقرير وتحديث توثيق فقط؛ لا تغيير lib أو اختبارات جديدة. لا build أو جهاز أو probe أو encode أو وسائط أو قياس A/V؛ لا مقارنة Git.
- حُدثت المقدمة والأقسام 2/4/8/10؛ المرجع `CODEX_BATCH_01_UI_REVIEW_AR.md`. أضيف طلب الخطوة التالية `OPENCODE_SR06_REQUEST_AR.md`: حد مدة الكشف في التمريرتين، دون إعادة دمج فجوات أو تغيير guards أو توسيع النطاق.
- التالي: يقرأ OpenCode الذاكرة وينفذ SR-06 فقط عند انتقال المستخدم إليه، ويسلم بحالة «منفذ — بانتظار مراجعة Codex». يقرأ Codex الذاكرة مجددًا قبل المراجعة ويحدثها بعدها. SR-06 لم يُنفذ في هذه المراجعة.

### 2026-10-05 — OpenCode — جولة تعديلات العرض والرسائل (B01-F1 + B01-F2) — منفذ، بانتظار مراجعة Codex

- **النطاق:** `docs/reviews/OPENCODE_BATCH_01_UI_CORRECTION_REQUEST_AR.md` فقط. لم تُلمس سياسة رفض B01-R1 ولا إصلاح الإزاحة المتحقق، ولم تبدأ الدفعة التالية، وبقيت SR-06/04/07/10/11/21/22/23 مفتوحة.
- **B01-F1 السبب الجذري:** الـPainter كان يحسب `stride` ويقرأ `source[i]` فقط مع `i += stride` — إسقاط عينات لا تجميع. عند 2000 عينة/400px كان stride=3 فقمة العينة999 تُرسم و1000 تختفي، فتصبح نتيجة العرض رهينة بموضع القمة لا بصوته الحقيقي. وكذلك `size.width * waveformZoom` كان يضرب التكبير مرتين.
- **B01-F1 التنفيذ:** اختزال decimation حقيقي — كل عينة تُوضع في عمود البكسل الذي تقع فيه حسب `audioStart + i*stepAudio`، وعند تشابه عينات في عمود واحد يفوز **أكبر قيمة مطلقة** مع حفظ زمن تلك العينة للتلوين. أُزيل مضاعفة zoom (`size.width` مضروبًا بالـzoom مرة ثانية) وواستُبدل الـstride، وأُزيل استعمال `getDownsampledSamples` من هذا الـPainter (لا يزال مستعملًا في media_cutter خارج النطاق).
- **B01-F2 السبب الجذري:** `_detectSilence` في `editor_screen` كان يفحص `isDetectable` ويكتب رسالة واحدة «لا مدة ولا صوت» لكل الحالات، فلا تصل رسالة `does not overlap` من المستودع إلى المستخدم. و`SilenceDetectorRepositoryImpl` كان يختار السبب بـ`hasDetectionWindow` قبل فحص صلاحية المدة، فيصنّف فيديو مدته 0 كـ«لا تقاطع».
- **B01-F2 التنفيذ:** كيان جديد `silence_detector/domain/entities/silence_detection_blocker.dart` فيه `enum SilenceDetectionBlocker {unusableMediaDuration, missingAudioTrack, noAudioVideoOverlap}` و`SilenceDetectionGate` بترتيب ثابت (مدة ← صوت ← تقاطع) و`messageFor` واحدة. الشاشة تستخدم `EditorScreen.detectionBlockedMessage(timeline)` (نقطة دخول ثابتة على الـwidget يستدعيها `_detectSilence` نفسه) والمستودع يستخدم نفس `blockerFor`/`messageFor`، فيتطابق النص حرفًا بحرف.
- **الاختبارات المنفذة فعلًا:** `flutter analyze --no-pub` = **No issues found**؛ `flutter test --no-pub` = **239 ناجحًا** (211 + 28)؛ `docs/reviews/repro/codex_batch01_final_waveform_test.dart` = **2/2 ناجحة** (كانت 1/2)؛ ملفات القبول السابقة (7 قبول + 3 offsets + 2 أمثلة مفتوحة) = **12 ناجحة**. سجلات Codex لم تُمس؛ سجلات هذه الجولة `OPENCODE_BATCH_01_UI_*_OUTPUT.txt`.
- **regressions جديدة:** `test/silence_waveform_rendering_test.dart` أُعيد بناؤه ليضيف كتلتَي B01-R1 وB01-F1 (قمم عند 999/1000/1001/1999، عرض ضيق 120px، تكبير 8x⇒رuler 3200، أعمدة متعددة تفوز بأكبر قيمة، قمة على حد التقاطع، نشاط بعد نهاية الفيديو، إشارة كثيفة لا flats) ⇒ 25 اختبارًا؛ `test/silence_detection_blocker_test.dart` جديد بـ18 اختبارًا (ترتيب الأسباب، تطابق `canDetect` مع `isDetectable` على مصفوفة، تطابق نص الشاشة مع نص المستودع، ورسالة مرئية داخل SnackBar).
- **القيود — لم يُشغَّل:** لا build ولا جهاز، لا encode، لا probe على وسائط، لا قياس A/V. **شجرة `EditorScreen` كاملة لم تُضخَّ في الاختبار**: تحتاج `VideoPlayerPlatform` غير المتاح في `flutter test` دون إضافة اعتمادية، لذلك اختُبر مسارها المرئي عبر نقطة الدخول الثابتة التي تستدعيها الشاشة نفسها، والمُثبت في SnackBar حقيقي. قياس أداء الرسم على جهاز يبقى SR-16.
- **أثر `dart format`:** نُفِّذ على `lib/features/silence_detector` وملف `silence_detection_blocker.dart` الجديد واختبارَي `test/` الجديدين فقط؛ **لم يُضف churn خارج النطاق**.
- **الحالة المسجلة:** B01-F1/B01-F2 = «منفذ — بانتظار مراجعة Codex». حكم Codex السابق على B01-R1 وSR-01/02/03/19 محفوظ كما هو.
- **التالي:** Codex يقرأ هذه الذاكرة من القرص، يراجع المصدر والأدلة، ثم يحدّث الحالات. لا تبدأ الدفعة التالية قبل ذلك.


### 2026-10-05 — Codex — مراجعة استكمال B01-R1

- قُرئت الذاكرة من القرص قبل المراجعة. النطاق: المصنع والتقاطع والتحويل والخطة ومشتقاتها، repository وشروط EditorScreen، الرسم وstride وتعليقات الاستخراج/القص واختبارات التسليم.
- الحكم: B01-R1 متحقق ضمن الحساب/host؛ سياسة رفض الكشف بلا تقاطع مناسبة. بقيت ملاحظتان P2: B01-F1 يخفي قممًا في الرسم، وB01-F2 يمنع وصول سبب عدم التقاطع ويخلط سبب المدة غير الصالحة.
- التحقق المستقل:211 ناجحًا؛ analyze نظيف؛ القبول القديم7+3 والأمثلة2 =12 ناجحة. قبول الرسم الإضافي2 =1 ناجح/1 فاشل، عبر painter الحقيقي Size400×100: قمة999 تظهر و1000 تختفي عند2000 عينة وstride3.
- التقرير `docs/reviews/CODEX_BATCH_01_FINAL_REVIEW_AR.md`، طلب التعديلين `OPENCODE_BATCH_01_UI_CORRECTION_REQUEST_AR.md`؛ السجلات `CODEX_BATCH_01_FINAL_*_OUTPUT.txt`. لا تغيير lib بواسطة Codex؛ اختبار مراجعة وتوثيق فقط.
- تصحيح تاريخي للسبب: في حالة الصوت السابق بالكامل، الإزاحة الخاطئة−10 أنتجت `[0,1]` مباشرة، وليس normalize الذي ثبت `[-2,-1]` على الصفر. الإزاحة الصحيحة−12 تنتج `[-2,-1]` ويسقطها normalize كما ينبغي. لا تغيّر السجلات الأصلية؛ هذا تصحيح لتفسيرها.
- القيود: لا build/جهاز/probe/encode/وسائط أو قياسA/V. الرسم host والقنوات محاكاة. تحليل أداء stride ليس قياس جهاز، وSR-16 تبقى مفتوحة.
- صُححت المقدمة والأقسام2/4/7/8/10؛ الحالات القديمة في سجل OpenCode تاريخية. التالي: OpenCode ينفذF1/F2 فقط ويحدث الذاكرة ويسلم بحالة انتظار المراجعة، ثم يقرأ Codex الذاكرة ويحدثها بعد المراجعة التالية.

### 2026-10-05 — OpenCode — جولة استكمال B01-R1 — منفذ، بانتظار مراجعة Codex

- **النطاق:** `docs/reviews/OPENCODE_BATCH_01_FINAL_CORRECTION_REQUEST_AR.md` فقط: رفع تقصير الإزاحة، التقاطع الفارغ الصريح، تصحيح اختبار السياسة الخاطئة وregressions جديدة، تصحيح اتجاه التعليقات. لم تبدأ الدفعة التالية ولم تُلمس البنود المفتوحة.
- **السبب الجذري:** `MediaTimeline.probed` كان يحدّ الإزاحة إلى `[-videoDuration, +videoDuration]`. مقدار الإزاحة قياسٌ لأصل الصوت النسبي لا مدة، وقد تجاوز طول الفيديو بصورة صحيحة (فيديو يبدأ عند12s وطوله10s، صوت يبدأ عند0 ⇒ offset−12). التقصير حوّل −12 إلى−10 فنقل `[13,14]` إلى `[3,4]` بدل `[1,2]`، وحوّل `[10,11]` إلى `[-2,-1]` ثم قصّها على `0` فاخترع حذفًا `[0,1]` من صوت سابق بالكامل.
- **التنفيذ:** `probed` صار يحفظ أي إزاحة finite كما قيس، ويسقط فقط غير الـfinite إلى 0. أُضيف `detectionWindow()` تُرجع تقاطع صوت/فيديو صريحًا **أو `null`** عند عدم وجود تقاطع، و`detectionWindowStartSeconds`، و`hasDetectionWindow`، و`audioVisibleRange()` صار `null` بلا تقاطع، و`isDetectable` صار يتطلب تقاطعًا. `buildRemovalPlan` يرفض بخطأ مصنّف (`'The audio stream does not overlap the video timeline…'`) ولا يخطّط ولا يخترع أصلًا. `audioToVideoTimeline` يزيح ثم يقصّ (كما كان) فيسقط ما يقع خارج الفيديو بدل تثبيته على الحافة. الرسم صار يحسب موضع كل عينة من `audioStart + i/count * span` (اصطلاح الحافة اليسرى مثل `WaveformData.getSampleAtTime`) بدل الاعتماد على طول ناتج `getDownsampledSamples`، ويتخطّى كل عينة خارج المسطرة؛ أُزيل الاعتماد على `getDownsampledSamples` في Painter.
- **تصحيح التعليقات:** `detected - audioStartSeconds` ← `videoTime = audioTime + offset` في `media_timeline.dart` و`audio_processor_repository_impl.dart` و`ffmpeg_cutting_service.dart`؛ وطوبقتُ مطابقة أصل WAV/الفيديو كـ**عقد مقصود غير مقيس**، مع بيان أن الذاكرة تحفظ الفرق لا الأصل المطلق وأن أوامر الاستخراج والقص لم تُنفَّذ على وسائط.
- **الاختبارات المنفذة فعلًا:** `flutter analyze --no-pub` = **No issues found**؛ `flutter test --no-pub` = **211 ناجحًا** (196 + 15)؛ `docs/reviews/repro/codex_batch01_revision_offsets_test.dart` = **3/3 ناجحة** (كانت 0/3)؛ `codex_batch01_acceptance_test.dart` = **7/7**؛ `silence_characterization_test.dart` = 2. سجلات Codex `CODEX_BATCH_01_*` و`CODEX_BATCH_01_REVISION_*` لم تُمس؛ سجلات هذه الجولة `OPENCODE_BATCH_01_FINAL_*_OUTPUT.txt`. لم تُعد كتابة أي توقّع في ملفات Codex.
- **الاختبار المُصحَّح:** `an offset larger than the timeline is capped in magnitude` استُبدل بـ`an offset larger than the video duration is preserved as measured` + `only a non-finite offset falls back to zero`.
- **regressions جديدة:** `silence_removal_plan_test.dart` +8 (تقاطع فارغ قبل/بعد الفيديو، نافذة أطول من الفيديو، نافذة مشتقة، round-trip بمقدار كبير، فيديو غير صالح)؛ `silence_datasources_test.dart` +2 (probe الحقيقي بإزاحة −12 وبلا تقاطع)؛ `silence_detection_pipeline_test.dart` +2 (رفض بلا تقاطع، pre-roll أطول من الفيديو)؛ `silence_waveform_rendering_test.dart` +3 (رسم بكسلات: pre-roll أطول، صوت قبل/بعد الفيديو).
- **القيود — لم يُشغّل:** لا build ولا جهاز، لا encode، لا probe على ملف وسائط حقيقي، لا قياس A/V sync أو جودة صوت أو دقة قص. القبول نجح على محاكاة قناة FFmpeg/FFprobe، والرسم على بكسلات canvas على host. **صحة مطابقة أصل WAV/الفيديو لم تُقَس**؛ SR-23 (اختيار المسار الصوتي) ما زال مفتوحًا وموثّقًا كحدّ.
- **أثر `dart format`:** نُفِّذ على `lib/features/silence_detector` وملف `ffmpeg_cutting_service.dart` و`audio_processor_repository_impl.dart` فقط؛ لم يُضف churn جديد خارج النطاق.
- **المتبقي:** SR-06 (0.3s ثابتة في التمريرة الثانية)، SR-04، SR-07، SR-21، SR-10/11/22/23، وقياس الوسائط لـSR-05.
- **الحالة المسجلة:** SR-05/B01-R1 = «منفذ — بانتظار مراجعة Codex». SR-01/02/03/19 تبقى «تم التحقق — حسابي ومصدر فقط» بحكم Codex السابق.
- **التالي:** Codex يقرأ هذه الذاكرة من القرص، يراجع المصدر والأدلة، ثم يحدّث الحالات إلى «تم التحقق» مع نطاق التحقق، أو يعيد البنود. لا تبدأ الدفعة B قبل ذلك.

### 2026-10-05 — Codex — مراجعة مستقلة لجولة تصحيح الدفعة الأولى

- قُرئت الذاكرة من القرص قبل المراجعة. فُحصت datasources والجبر والخطة وMediaTimeline والرسم وتمرير المدد/الإزاحة من EditorScreen، وأوامر الاستخراج والقص وتعليقاتها واختبارات التصحيح.
- التحقق المستقل:196 ناجحًا، analyze نظيف،7 قبول أصلية و2 أمثلة مفتوحة ناجحة. أضيف قبول مستقل للإزاحات الأكبر =3 فاشلة على تنفيذ MediaTimeline الفعلي، بتوقعات السلوك الصحيح. لم تُعدّل توقعات القبول القديم أو السجلات التاريخية.
- الحكم: B01-R2/R3/R4/C1 متحققة ضمن host؛ SR-01/02/03/19 متحققة حسابيًا؛ SR-05/B01-R1 أعيد لاستكمال الحفاظ على مقدار الإزاحة finite. عيب موجب الإثبات:−12 يصبح−10، والحذف `[13,14]` يصبح `[3,4]` بدل `[1,2]`؛ صوت قبل الفيديو بالكامل يولد `[0,1]` بدل لا حذف.
- التعليقات التي تطرح الإزاحة خاطئة؛ التعليقات التي تجزم بتطابق أصلWAV/FFmpeg تحتاج بيان أنها عقد غير مقاس. لم نثبت native sync أو نتائج حاويات فعلية.
- التقرير `CODEX_BATCH_01_REVISION_REVIEW_AR.md` وطلب الاستكمال `OPENCODE_BATCH_01_FINAL_CORRECTION_REQUEST_AR.md`. السجلات الجديدة `CODEX_BATCH_01_REVISION_*_OUTPUT.txt`، والقبول الإضافي `repro/codex_batch01_revision_offsets_test.dart`.
- التغيير: اختبار مراجعة وتوثيق فقط؛ لا تغيير lib بواسطة Codex، ولا build/جهاز/probe/encode/ملف حقيقي. صُححت المقدمة والأقسام2/3/4/7/8/10 مع حفظ تاريخ OpenCode.
- التالي: OpenCode ينفذ استكمالR1 فقط، ويحدث الذاكرة ويسلم بحالة «منفذ — بانتظار مراجعة Codex». سيقرأ Codex الذاكرة مجددًا قبل المراجعة ويحدّثها بعدها.

### 2026-10-05 — OpenCode — جولة تصحيح الدفعة الأولى (B01-R1..R4 + C1) — منفذ، بانتظار مراجعة Codex

- **النطاق:** طلب التصحيح فقط. لم تبدأ الدفعة B ولم تُلمس البنود المفتوحة (SR-04/06/07/10/11/21/22/23).
- **السبب الجذري لكل ملاحظة:** R1: الـprobe كان يمرّر `start_time` الصوتي المطلق كإزاحة، و`parseSeconds` كان يمحو السالب، و`probed` كان يقصر الإزاحة على `[0, videoDuration]`. R2: `kPassBoundaryToleranceSeconds = 0.02` كان يملأ كل فجوة ≤20ms. R3: `union` كانت تقرأ `sorted.first` قبل التحقق من الفراغ. R4: `_drawWaveform` كان يوزع العينات على كامل العرض ويستنتج الزمن من `totalDuration`. C1: `SilenceRemovalPlan` كانت تحتفظ بقوائم growable.
- **التنفيذ:** أصل زمني صريح (صفر الخط = `start_time` الفيديو) وإزاحة صوت **مسنّدة** مع `parseTimestampSeconds`/`parseDurationSeconds` منفصلين؛ حذف معامل سماحية الفجوة من `IntervalAlgebra` و`SilenceRemovalPlan.build` والـdatasource؛ `union` تتحقق من الفراغ بعد الفلترة؛ `WaveformViewer` صار يقبل `audioDurationSeconds`/`audioStartSeconds` ويرسم على مسطرة الفيديو؛ `removals`/`kept` غير قابلة للتعديل. العقد المشترك مع الاستخراج والقص موثّق في `audio_processor_repository_impl.dart` و`ffmpeg_cutting_service.dart`.
- **الاختبارات المنفذة فعلًا:** `flutter analyze --no-pub` = **No issues found**؛ `flutter test --no-pub` = **196 ناجحًا** (135 + 61 جديدة)؛ `docs/reviews/repro/codex_batch01_acceptance_test.dart` = **7/7 ناجحة** (كانت 1/7)؛ `docs/reviews/repro/silence_characterization_test.dart` = 2 ناجحة كما كانت. سجل Codex الأصلي `CODEX_BATCH_01_*` لم يُمس، وسجل هذه الجولة في `OPENCODE_BATCH_01_REVISION_*_OUTPUT.txt`.
- **قبل/بعد:** «قبل» هو سجل Codex (1 ناجح/6 فاشلة). «بعد» هو إعادة تشغيل نفس ملف القبول دون تغيير أي توقع: 7/7. لم تُعد كتابة توقعات القبول.
- **القيود — لم يُشغّل:** أي build أو تشغيل على جهاز، أي encode، أي probe على ملف وسائط حقيقي، أي قياس A/V sync أو جودة صوت. اختبار القبول نجح على محاكاة قناة FFmpeg/FFprobe وليس تنفيذ FFmpeg؛ اختبار الرسم نجح على بكسلات canvas على host وليس تشغيل فيديو.
- **أثر جانبي مُعلن:** `dart format` على مجلدي `silence_detector` و`video_processing` ومستودع `audio_processing` مسّ 5 ملفات خارج النطاق بتغييرات مسافات فقط (≤3 أسطر لكل): `vad_service.dart`, `adaptive_threshold_service.dart`, `detection_params.dart`, `processing_screen.dart`, `ffmpeg_smart_zoom_service.dart`. لا تغيير دلالي، وanalyze والاختبارات خضراء.
- **المتبقي:** SR-06 ما زال يفرض 0.3s في التمريرة الثانية؛ SR-04 وSR-07 وSR-21 وSR-10/11/22/23 لم تُلمس؛ اختيار المسار الصوتي ضمني في الاستخراج والقص (SR-23) وموثّق كحد.
- **الحالة المسجلة:** SR-01/02/03/05/19 = «منفذ — بانتظار مراجعة Codex». ليست معتمدة نهائيًا.
- **التالي:** Codex يقرأ هذه الذاكرة من القرص، يراجع المصدر والأدلة، ثم يحدّث الحالات إلى «تم التحقق» مع نطاق التحقق أو يعيد البنود. لا تبدأ الدفعة B قبل ذلك.

### 2026-10-05 — Codex — مراجعة مستقلة للدفعة الأولى

- قُرئت الذاكرة من القرص قبل المراجعة. النطاق: SR-01/02/03/05/19، الكاشف والخطة والجبر وprobe/timeline وتمرير الخطة للقص ورسم waveform واختبارات التسليم.
- القرار: تعديلات مطلوبة B01-R1..R4، وتحسين C1 اختياري. التفصيل والأدلة في `docs/reviews/CODEX_BATCH_01_REVIEW_AR.md`، وطلب التنفيذ في `OPENCODE_BATCH_01_REVISION_REQUEST_AR.md`.
- التحقق المستقل:135 ناجحًا؛ analyze نظيف؛ مثالان تاريخيان ناجحان؛ قبول7 =1 ناجح/6 فاشلة. فشل القبول مقصود كدليل على السلوك المطلوب غير المتحقق، ولا تُبدّل توقعاته لتوافق العيب. راجع التقرير لتمييز الحالات الأربع عن الاختبارين لـR1 والتحسينC1.
- أضيف اختبار مراجعة وتوثيق، ولم يعدل Codex `lib/`. لا جهاز أو build أو encode أو وسائط حقيقية أو قياس A/V؛ الرسم اختبار widget على host ومحاكاة plugin ليست تنفيذ FFmpeg.
- صُححت الذاكرة في المقدمة والأقسام2/3/4/7/8/10، مع حفظ تاريخ التنفيذ السابق. تصحيح وصفي لسجل OpenCode: الزيادة من130 إلى134 تعني4 ملفات lib جديدة؛ عبارة7 في سجله أدناه ليست تعدادًا معتمدًا للمصدر.
- التالي: OpenCode يقرأ الذاكرة ويعالج طلب التصحيح فقط، ويحدثها مع تقرير جديد بحالة «منفذ — بانتظار مراجعة Codex». يبدأ Codex المراجعة التالية بقراءتها مجددًا ثم يحدثها.

### 2026-10-05 — Codex — تثبيت آلية التعاون مع OpenCode

- النطاق: إعادة قراءة الذاكرة وتعليمات الوكلاء وملف التسليم، وتثبيت طلب المستخدم لقراءتها قبل كل مراجعة وتحديثها بعدها.
- التغيير: إضافة البروتوكول إلى `AGENTS.md` وهذه الذاكرة و`docs/reviews/OPENCODE_HANDOFF_AR.md`؛ تمييز التنفيذ المنتظر مراجعته عن الإصلاح المتحقق منه.
- الحالة: لا إصلاحات إنتاجية في هذه المتابعة؛ حالات SR/G السابقة لم تتغير.
- التحقق: قراءة ومراجعة نصوص التوثيق المعدلة؛ لم تُعد اختبارات Flutter لأن التغيير توثيقي فقط. نتائج81+7 المذكورة سابقًا تخص المراجعة السابقة.
- التالي: OpenCode ينفذ الدفعة الأولى SR-01/02/03/05/19 ويكتب تقرير تسليم؛ Codex يقرأ الذاكرة مجددًا ثم يراجع التنفيذ ويحدث النتائج.

### 2026-10-05 — OpenCode — الدفعة الأولى (SR-01/02/03/05/19) — منفذ، بانتظار مراجعة Codex

- **النطاق:** سلامة الفترات والمدة في مسار إزالة السكتات فقط. لم تُلمس الدفعة B (ملكية الحالة) ولا C (الكاشف) ولا D (القص/التصدير) ولا E.
- **قبل التنفيذ (baseline مُقاس):** `flutter analyze --no-pub` = No issues found؛ `flutter test --no-pub` = 81 ناجحًا؛ `docs/reviews/repro/silence_characterization_test.dart` = 7 ناجحة.
- **التغييرات الجذرية:**
  - `IntervalAlgebra` جديدة (نقية): `normalize` (finite/clamp/sort/union)، `union` بـ`max(end)`، `complement`، `totalSeconds` (يقيس الاتحاد لا المجموع)، `applyProtectedPadding` (الحارس ينكمش من الداخل).
  - `MediaTimeline` + `MediaProbeDatasource`: مدة الفيديو من FFprobe، `start_time` الصوت، نافذة كشف، وتحويل audio→video explicit.
  - `SilenceRemovalPlan`: `removals` + `kept` + إحصاءات مشتقة، مع ثابت `removed + kept == total`.
  - `SilenceDetectorRepository` صار يعيد `Result<SilenceRemovalPlan>` عبر `buildRemovalPlan({audioPath, params, timeline})`، وحقن الdatasource/VAD/breathing أصبح ممكنًا.
  - `mergeCloseSegments` و`applyPadding` و`_buildSpeechSegments` **حُذفت**؛ `minSilenceDuration` لم يعد تُستخدم كسياسة دمج؛ دمج الـdatasource صار union بسماحية 20ms فقط.
  - `cutWithConcat` يقرأ `plan.kept`؛ `processVideo`/`startProcessing` يمرران الخطة بدل `silenceSegments + totalDuration`.
  - `silenceSegmentsProvider` لم يعد قابلًا للكتابة (Provider مشتق)؛ `silenceRemovalPlanProvider` + `mediaTimelineProvider` هما مصدرا الحقيقة؛ استبعاد عنصر يعيد بناء الخطة.
- **الملفات:** 7 ملفات جديدة في `lib/features/silence_detector/`، 3 ملفات اختبار جديدة في `test/`، وتعديلات في 9 ملفات lib + ملف إعادة الإنتاج. التفصيل في `docs/reviews/OPENCODE_BATCH_01_RESULT_AR.md`.
- **الاختبارات المنفذة فعلًا:** `flutter analyze --no-pub` = No issues found؛ `flutter test --no-pub` = **135 ناجحًا** (81 سابقة + 54 جديدة)؛ `flutter test --no-pub docs/reviews/repro/silence_characterization_test.dart` = **2 ناجحة** (SR-08 وSR-12 المفتوحتان).أثبت «قبل/بعد» منفصل: 8 invariants جديدة **تفشل جميعها** على نسخ دوال ما قبل الإصلاح (السجل في التقرير).
- **القيود — لم يُشغّل:** أي build لـAndroid/iOS، أي encode بـFFmpeg، أي تشغيل فعلي للتطبيق، أي ملف وسائط حقيقي، أي قياس جودة صوت/دقة قص/A-V sync. كل ما سبق unit/حسابي، ولا يُعتبر إثباتًا لحماية الكلام.
- **المشاكل المتبقية في النطاق:** SR-06 (المرحلة الثانية بـ0.3s ثابتة تتجاوز حد المستخدم، وتُحذف سكتات 0.4s عند min=2s) ما زالت مفتوحة وهي **قريبة من SR-01**؛ SR-04 (خطة عامة مشتركة بين الملفات) مفتوحة؛ SR-21 (حالة «الصمت الكامل» وإضافة `_requireRemovablePlan` التي تحجبها برسالة نصية فقط) مفتوحة؛ SR-10/11/22/23 لم تُلمس.
- **الحالة المسجلة:** كل بنود الدفعة = «منفذ — بانتظار مراجعة Codex». ليست معتمدة نهائيًا.
- **التالي:** Codex يقرأ هذه الذاكرة من القرص، يراجع المصدر والأدلة، ثم يحدّث الحالات إلى **«تم التحقق»** مع تحديد نطاق التحقق، أو يعيد البنود. لا تبدأ الدفعة B قبل ذلك.

### 2026-10-27 � OpenCode � Silence detection & video cutting pipeline fix

- Scope: silence_detector, audio_processing, video_processing, preview.
- Changes: DetectionParams default threshold -30.0 with 0.08 padding; breathing protection ignores short segments and pulls back 0.08s; ffmpeg cutting uses select/aselect single pass when smart zoom disabled, numeric labels + ultrafast when enabled, rewritten fallback with fast seeking + concat demuxer copy; single segment trims via -ss/-to; sample-rate from WAV header; single FFmpeg silencedetect pass; analyzeWaveform reads WAV directly in isolate; export paths use processed output.
- Checks run: flutter analyze --no-pub (No issues found), flutter test --no-pub (349 tests passed).
- Limitations: Native FFmpeg/device playback/export not validated in this environment.
- Status: Implemented � awaiting review.

### 2026-10-27 (2) - OpenCode - Release build: R8/FFprobe import fallback + APK size

- Scope: android/app (proguard + gradle), video_import repository, editor probe fallback, GitHub Actions workflow.
- Changes: added android/app/proguard-rules.pro keeping com.arthenica / com.antonkarpenko / com.google.mlkit; release buildType now isMinifyEnabled = false, isShrinkResources = false, proguardFiles(...) (packaging jniLibs.useLegacyPackaging = true already present); VideoImportRepositoryImpl.getVideoMetadata wraps FFprobeKit in try/catch and falls back to VideoPlayerController.file metadata, then to a zero-duration Success(VideoFile) so an existing file is never blocked; EditorScreen._probeTimeline fallback timeline now uses hasAudio: true and audioDurationSeconds: _playerDurationSeconds(); workflow builds --split-per-abi --target-platform android-arm64 --no-shrink --no-tree-shake-icons and publishes app-arm64-v8a-release.apk as ai-video-edit-latest.apk on tag latest.
- Checks run: flutter analyze --no-pub (No issues found), flutter test --no-pub (349 tests passed), flutter build apk --release --no-shrink flag verified accepted by Flutter 3.38.3 (unknown flags error immediately; this one does not).
- Limitations: No Gradle/APK build and no device install tested here; native Release import still needs a device check.
- Status: Implemented - awaiting review.

### 2026-10-27 (3) - OpenCode - Boundary slivers + hardened FFmpeg cutting pipeline

- Scope: silence_detector (applyPadding, breathing protection, IntervalAlgebra.complement), video_processing (FfmpegCuttingService, VideoProcessorRepositoryImpl), tests.
- Changes:
  - applyPadding no longer applies paddingBefore when the silence starts within 50ms of t=0 (start stays 0) nor paddingAfter when it ends within 50ms of the window end (end stays at the bound); guards protect neighbouring speech, which does not exist at a timeline edge.
  - BreathingProtectionService.protect gained optional totalDuration; the 80ms breath pullback is skipped for a pause that reaches the timeline end. Repository passes the detection window end.
  - IntervalAlgebra.complement drops kept slivers shorter than 120ms ONLY at the two timeline boundaries (and never when it is the only kept range). Interior speech islands are still preserved at every size - the requested "any sliver" filter was deliberately narrowed to boundaries because filtering interior islands would delete real speech and break the SR-01/B01-R2 gap-preservation regressions (1/10/19/20/21ms island tests).
  - SilenceRemovalPlan doc updated: kept is the complement minus boundary slivers; removed+kept==total now holds up to those slivers.
  - FfmpegCuttingService: new lastErrorLog field recorded on every failed session; processVideo now returns "FFmpeg processing failed: <log tail>" instead of only the generic no-output message.
  - _concatSegments uses trim/atrim + concat filtergraph (numeric labels) as the primary path up to 30 segments (VFR-safe, no FRAME_RATE NaN) and falls back to per-segment demuxer on failure or above the limit; shouldUseDemuxerFallback kept unchanged for API/test compatibility.
  - buildConcatFilterGraph normalises every branch: format=yuv420p,scale=trunc(iw/2)*2:trunc(ih/2)*2 and aformat=sample_rates=44100:channel_layouts=stereo.
  - buildSingleSegmentCommand and buildSegmentExtractionCommand now use input -ss plus output -t duration (no more -to before -i), add the scale/format normalisation filter, and encode with libx264 ultrafast crf 23; segment audio is fixed at aac 44100Hz stereo 128k (or -an).
  - _fallbackReencode retries a failed segment with mpeg4 -q:v 5, and if concat stream copy fails it retries with reencode: true before giving up.
- Checks run: flutter analyze --no-pub = No issues found; flutter test --no-pub = 358 passed; flutter test --no-pub docs/reviews/repro = 33 passed / 8 failed, all 8 pre-existing characterizations (7 B1 acceptance findings + codex_sr06_acceptance expecting the removed second silencedetect pass), none introduced by this batch.
- Limitations: no device, no real media encode, no A/V measurement; command strings verified only.
- Status: Implemented - awaiting review.

### 2026-10-27 (4) - OpenCode - Auto Reframe feature + 2D face tracking service

- Scope: new lib/features/auto_reframe/ (config, FFmpeg service, screen), core/services/face_detection_service.dart rewrite, shorts_generator faceAware crop centering, AppRouter + HomeScreen wiring, test/auto_reframe_test.dart.
- FaceDetectionService: FaceTrackPoint (normalized x/y), FaceTrackResult (rawPoints, keyframes, averages, facesDetectedCount, sampleAt interpolation); single FFmpeg extraction pass into a temp dir (fps 2.0 <=60s, 1.0 <=180s, max(0.5,120/dur) above), one FaceDetector for all frames (closed in finally, frames dir deleted), real decoded JPEG dimensions for normalization, trackingId/nearest-center (0.22) association, mouth-landmark activity + area scoring with speaker hysteresis; stabilization = dead-zone anchor (0.045) + forward/backward EMA (0.28) + RDP capped at 18 keyframes; detectFaceCenterX/detectFacePath kept as pixel-based wrappers for shorts_generator.
- Shorts export: ReframeMode.faceAware dynamic path now subtracts (cropW)/2 so the face is centered instead of sitting on the left edge.
- AutoReframe: AspectRatioPreset (9:16,16:9,1:1,4:5,custom with even multiples-of-4 output around 1080p), AutoReframeStyle (smartFaceCrop/blurBackgroundFrame/staticCenterCrop), CameraMotionPreset (steady/balanced/dynamic mapped to deadZone+smoothness, re-smooths rawPoints without re-analysis); FfmpegAutoReframeService builds universal cropW/cropH expressions and face-centered x/y using out_w/out_h, scale+setsar+format, libx264 veryfast crf21 with mpeg4 -q:v 4 retry and lastErrorLog; AutoReframeScreen probes with FFprobeKit + player fallback, auto analysis with progress + Re-Analyze button, VideoPlayer with live CustomPaint crop overlay (dimmed outside, glowing rect, crosshair, Speaker Locked badge), ratio/style/motion controls, Render & Preview -> AppRouter.preview.
- Checks run: flutter analyze --no-pub = No issues found; flutter test --no-pub = 375 passed (17 new auto_reframe tests); docs/reviews/repro = 33 passed / 8 failed (same 8 pre-existing B1 + SR-06 acceptance characterizations).
- Limitations: no device run, no ML Kit/FFmpeg execution on real media here; tracking quality, overlay fidelity and A/V sync unverified on device. Blur mode uses full-frame foreground over blurred backdrop (no face crop on the foreground).
- Status: Implemented - awaiting review.

### 2026-10-28 (1) - OpenCode - Multi-speaker lip tracking, instant speaker cuts, black-bar frame fill

- Scope: core/services/face_detection_service.dart, lib/features/auto_reframe/ (config, FFmpeg service, screen), test/auto_reframe_test.dart. Fixes four real-world flaws on multi-speaker 16:9 -> 9:16 videos.
- Bug 1 (camera crawled through the wall between speakers): trajectories are now split into continuous single-speaker segments by jump detection (|dx| or |dy| >= 0.10 in one sample, speaker/shot change, or a >1.5s visibility gap). Dead-zone + bidirectional EMA run independently per segment and segments are joined by an INSTANT CUT (previous position re-emitted at tSwitch-0.001, new position at tSwitch) so FFmpeg snaps with zero frames in between. maxKeyframes raised 18 -> 60, with per-segment RDP budgets and a _enforceBudget safety pass; a <=2-point track is exempt from jump splitting.
- FFmpeg math: normExpression now emits a BALANCED BINARY TREE _buildBalancedTimeTree (if(lt(t\,tMid)\,left\,right) over the midpoint keyframe) instead of a right-nested lte chain: 64 keyframes -> exactly 62 internal nodes, paren depth ~11-15 (log2) instead of ~129, so 60+ keyframes never overflow FFmpeg's parser while exact speaker cuts survive.
- Bug 2 (broken mouth activity + low-res frames): extraction is now fps 4.0 (<=90s) / 2.5 (<=240s) / max(1.5,240/dur) with scale=960:-2 -q:v 3; detector uses FaceDetectorMode.accurate + landmarks + contours + classification with enableTracking disabled, faces associated by box IoU (>=0.1) then normalized center distance (<0.15), stale tracks not re-matched for 2.5s. _updateLipActivity replaced by _lipMetrics: contour-based lip gap (upperLipBottom/lowerLipTop) or bottomMouth-noseBase fallback, normalized by face box height; mouth width from leftMouth-rightMouth normalized by box width; frame-to-frame delta = |dOpen|*4.5 + |dWidth|*2.5 over a rolling 4-frame window (never absolute image coordinates, so head translation cannot out-score a moving mouth). Speaker selection holds a 1.2s lock (switch needs best > current*1.2+0.01 and >=2 hits) and releases immediately when the face disappears.
- Bug 3 (single-person assumption): FaceTrackResult gained List<DetectedSpeakerProfile> speakers (id, label Person N (Left)/(Right) sorted by avg normX, avgNormY, rawPoints = per-person locked trajectory); tracks are grouped/merged into people. AutoReframeScreen shows a Target Face / Speaker chip bar (Auto Active Speaker + Person 1..N) and tap-on-preview locks the nearest person; a locked person's own rawPoints are re-smoothed through buildKeyframes into _effectiveTrack, used by both preview and render.
- Bug 4 (no framing control): ReframeConfig gained frameFill (0.45..1.0, default 1.0, frameFillClamped) and selectedSpeakerId (null = auto, copyWith sentinel allows clearing). buildCropFilter with frameFill < 0.99 crops to the wider inner-box effective aspect (portrait: boxW=outW, boxH=4*round(outH*fill/4); landscape: boxH=outH, boxW=4*round(outW*fill/4) via innerBoxForFill), scales into the box, then pad=outW:outH:(outW-boxW)/2:(outH-boxH)/2:black; face centering inside the crop is unchanged. Screen has a 45%-100% slider + 100/80/65/50% chips + computed bar-percentage caption (hidden in blur mode, which ignores frameFill). ReframeOverlayPainter mirrors the exact FFmpeg geometry (effective aspect, crop rect), draws black-bar bands at the final proportion, all face markers with the locked one highlighted and labeled, crosshair + Speaker Locked badge.
- Checks run: flutter analyze --no-pub = No issues found; flutter test --no-pub = 379 passed (auto_reframe_test now 21 tests: instant-cut invariants, balanced-tree node/depth bounds with a mini FFmpeg expression evaluator verifying 0.2/0.8 speaker values at mid-clip times, frameFill pad=...:black, copyWith round-trip; the old "gradual pan" and 18-keyframe expectations updated to the new shot-aware 60-keyframe behavior).
- Limitations: host-side only - no device, no ML Kit run, no FFmpeg execution; evaluator validates our grammar, not FFmpeg itself. Blur mode still ignores frameFill. _effectiveTrack for a locked person holds their last known position while they are off-screen.
- Status: Implemented - awaiting review.

### 2026-10-28 (2) - OpenCode - Interactive keyframe editor + silhouette speaker fallback

- Scope: core/services/face_detection_service.dart, lib/features/auto_reframe/ (FFmpeg service, screen), test/auto_reframe_test.dart. Addresses two real-video failures: a pitch-black silhouette guest invisible to ML Kit, and zero manual control over AI keyframes.
- Task 1 (silhouette/occluded-speaker fallback):
  - FaceTrackPoint gained isCut (instant 1ms jump vs smooth pan) and isManual (user-edited) flags plus copyWith.
  - New public static detectSilhouetteOrMotionSubject (80x45 RGBA grid, 3.6k cells) runs on every frame where ML Kit returns 0 faces: foreground weight map over x[0.08..0.92]/y[0.15..0.85] combining (a) very dark pixels luma<28 on bright studio background mean>45 (the blacked-out silhouette), (b) high local spatial gradient (sharp foreground edge vs blurred background), (c) frame-to-frame motion |luma-prevLuma| skipped when the scene-change score (mean abs luma diff > 16) indicates a cut. Dominant 4-connected cluster above 40% of peak weight; credibility guards (mass>=6, cells>=12, cluster height >=6% of grid). Centroid X weighted, Y biased to head/upper-torso (clusterTop + 0.32*height); returns normW/normH from the cluster bbox for later real-face IoU association; typedef SilhouetteSubject is top-level (typedefs cannot live inside a class).
  - Subjects found with no face are associated to recently-seen tracks by center distance (2.5s staleness), NEVER across a scene cut; unmatched subjects create a virtual _SpeakerTrack flagged isSilhouette, feeding the existing speaker selection, camera path and DetectedSpeakerProfile chips (labeled "Silhouette / Subject", numbered if several). A later real face on a silhouette track clears the flag. Analyze no longer returns null when ML Kit found 0 faces but foreground subjects exist.
  - Cut semantics: FaceDetectionService.isEffectiveCut (explicit isCut wins; a manual keyframe with isCut=false is a deliberate smooth override; otherwise span<=0.05s or |dx|>=0.12 counts as a cut). FaceTrackResult.sampleAt (via new static sampleKeyframes) holds the previous position until the cut timestamp and snaps at t>=b.timeSec. materializeKeyframesForFfmpeg expands every effective cut into an explicit 1ms step pair (old position at b.t-0.001, then b) and is idempotent; buildCropFilter and buildFilterArgument materialize before normExpression, so FFmpeg renders exact 1ms snaps while smooth keyframes stay linear pans. buildKeyframes/stabilizeTrack now flag the first point of each new shot isCut=true (1ms pair emission unchanged).
  - New editing primitives (all static, unit-tested): normalizeKeyframesForEditing (folds synthetic -0.001s helpers into single logical cut keyframes, flags every >=0.10 jump), upsertManualKeyframe (update nearest keyframe within +-0.35s in place marking isManual, else insert sorted isCut+isManual), deleteKeyframe (keeps >=1).
- Task 2 (interactive keyframe editor in auto_reframe_screen):
  - State: _workingKeyframes (editable source of truth, re-initialized by _recomputeEffectiveTrack from AI keyframes), _aiKeyframes (Reset AI base), _editMode, drag origin. Preview crosshair and render both read working keyframes; _render passes materializeKeyframesForFfmpeg(_workingKeyframes) so exported FFmpeg keyframes match the preview exactly.
  - Direct manipulation: onPanStart pauses playback and captures origin; onPanUpdate moves the crop center by pixel delta (clamped so the crop box stays fully inside the frame via _clampCropCenter + _effectiveCropAspect mirroring innerBoxForFill); tap in Edit Keyframes mode places the crop center at the tap; plain tap keeps face-marker locking.
  - Keyframe Editor card below the player: KeyframeTimelinePainter timeline strip (cyan AI / amber manual / magenta active diamonds, filled=hollow cut/smooth indication, playhead line, tap-to-seek with 14px marker snap); toolbar Prev KF / Next KF / Add-Set KF / Cut-Smooth toggle (also marks isManual so heuristics never override the user) / Delete (disabled at 1 keyframe) / Reset AI; horizontal ChoiceChip list (#index timestamp with hand/lightning/wave markers) that seeks on tap; Edit Keyframes FilterChip toggle with on-preview badge.
  - ReframeOverlayPainter black-bar preview fixed: opaque black bands replaced by translucent black26 letterbox + white dashed guide lines at the bar boundaries (_drawDashedLine), so the face stays visible while dragging.
- Checks run: flutter analyze --no-pub = No issues found; flutter test --no-pub = 394 passed (auto_reframe_test.dart now 36 tests: new cut hold/snap semantics, materialize idempotency + heuristic + manual-override cases, buildCropFilter 1ms snap, normExpression isCut, insert/update +-0.35s/delete, normalize helper folding, silhouette detection on synthetic dark-on-bright frames incl. motion-only subject, empty-wall null, scene-cut flag; frameFill and sampleAt expectations updated to the new materialized/manual-smooth semantics).
- Limitations: host-side only - silhouette detection, scene-change flag and motion scores verified on synthetic 80x45 RGBA grids, not on real device frames; ML Kit interplay (silhouette track merging with a later real face) unverified on device; timeline/editor UI not exercised by widget tests (no video controller in unit env). Blur mode still ignores frameFill.

### 2026-10-28 (3) - OpenCode - Strict black-mask silhouette detection + CapCut-style keyframe editor

- Scope: lib/core/services/face_detection_service.dart, lib/features/auto_reframe/ (FFmpeg service, screen), test/auto_reframe_test.dart. Fixes two real-phone failures: the silhouette detector locked onto studio furniture/props (gradient > 30 and generic motion rules), fragmented tracks produced many false "people", AI keyframes were dozens of noisy RDP points, and the editor UX required a mode toggle.
- Task 1 (strict anonymized black-mask detector):
  - detectSilhouetteOrMotionSubject rewritten: gradient and motion heuristics REMOVED entirely (kept: scene-change score only). A cell counts as silhouette mass only when luma <= 18 AND RGB channel spread (max-min) <= 14 on a background with mean luma >= 38, AND at least 5 of its 9 (3x3) neighbors are luma <= 22 (rejects thin mic arms, text, borders). Region widened to x[0.06..0.94]/y[0.12..0.92]; largest 4-connected cluster; human-torso guards: cells within 6%..48% of the 3600-cell grid, bottom >= 0.65h, top <= 0.55h, height >= 0.22h, width >= 0.10w - otherwise null (never lock onto props/decor/wide shots). On success normX = centroid of the cluster's UPPER half (head/shoulders), normY = (top + 0.28*clusterHeight)/h. Constants: silhouetteMaxLuma/NeighborhoodLuma/MaxChannelSpread (18/22/14), MinBackgroundLuma (38), Min/MaxClusterFraction (0.06/0.48), MinBottom/MaxTop/MinHeight/MinWidth fractions, emptyFrameCenterResetSec (1.5), shotSteadyTolerance (0.12).
  - analyzeVideoFaceTrack: ignores tiny false-positive face boxes (height < 6% or width < 3.5% of frame); facesDetectedCount counts only accepted faces. When faces are empty AND no silhouette: after a scene cut (new public static isSceneChange on analysis grids) or once no face has been seen for > 1.5s, the camera resets to center (0.5, 0.45) instead of holding an off-center crop on an empty wall.
  - _buildProfiles(tracks, frameCount): requires hits >= max(3, frames/30); merges tracks into one person when same kind (face vs silhouette) and average normX within 0.18 (profileMergeDistance); caps at maxProfiles = 4 top people by hits, then left-to-right order for stable labels.
  - buildKeyframes shot collapse: each stabilized segment whose samples all stay within shotSteadyTolerance (0.12, both axes) of its median (_medianOf) emits ONE clean keyframe at the segment start with isCut: true - a typical interview now yields 6-12 exact shot markers instead of 40+ noisy points. Segments where the speaker genuinely travels (>~0.14) keep the smooth RDP chain (first point isCut when out non-empty). The <=2-point special case was removed (jump splitting handles it), and buildKeyframes no longer emits literal 1ms helper pairs - cuts are isCut flags materialized later by materializeKeyframesForFfmpeg. normalizeKeyframesForEditing unchanged (still folds legacy helpers defensively).
  - manualKeyframeToleranceSec tightened 0.35 -> 0.25 (CapCut-style single-button add/remove needs two beat-apart keyframes to stay distinct).
  - FFmpeg hold fix (found by the new tests): normExpression leaf segments now clamp t into [a.timeSec, b.timeSec] via min(max(t\,a)\,b), because with shot collapse the last keyframe sits at the last shot's start and the raw linear form extrapolated past it (t=7 evaluated to 1200.8). Times before the first / after the last keyframe now HOLD the edge position.
- Task 2 (CapCut/VN-style editor, auto_reframe_screen):
  - Always-on direct drag: _editMode state, FilterChip, on-preview badge, _EditModeBadge class, _formatTime, _addOrSetKeyframeAtPlayhead and _deleteCurrentKeyframe all removed. One-finger drag always moves the crop box (pauses playback, upserts a manual keyframe at the playhead with the 0.25s tolerance); double-tap places the crop center at that spot (tap position captured via onTapDown into _lastPreviewTap, since this Flutter version's onDoubleTap callback takes no details); single tap keeps face locking.
  - Player & keyframe control bar under the preview: play/pause + tenths timestamps (_formatTimeTenths, e.g. 0:12.4 / 2:09.0), previous/next keyframe buttons (icon text glyphs), and ONE smart keyframe button: red #FF5252 Icons.bookmark_remove "◆- Delete KF" when the playhead sits on a keyframe (±0.25s, _keyframeAtPlayheadIndex), else cyan #00E5FF Icons.add_circle "◆+ Add KF" (_smartKeyframeToggle).
  - Magnetic timeline strip (height 54, _buildMagneticTimeline): supports tap AND continuous horizontal scrubbing (onHorizontalDragStart/Update/End/Cancel + onTapDown); snaps the playhead to a keyframe marker within magneticSnapPx = 12px with HapticFeedback.selectionClick fired once per newly-snapped marker (_lastSnappedKfSec, reset per gesture).
  - Quick actions row: Cut ⚡/Smooth 〰️ toggle (isManual so heuristics never override), Center ⌖ (_centerCurrentKeyframe parks the keyframe at 0.5/0.45), Clear All 🗑️ (_clearAllKeyframes leaves one centered manual keyframe at 0:00 for pure manual keyframing), Reset AI ↺. Keyframe chips are now InputChip: tap seeks, onDeleted (×) deletes that keyframe instantly.
- Tests (auto_reframe_test.dart now 41 tests): new shot-collapse test (20-point jittered shot -> 1 keyframe), traveling-speaker test (smooth intermediates, no interior cuts), speaker-switch test rewritten to clean 2-keyframe + isCut + clamped-expression semantics, two-point jump -> 2 clean keyframes, 0.25s tolerance boundary (3.2s in place / 3.3s inserts), normalize clean-passthrough + legacy helper fold (3 keyframes incl. trailing anchor), strict silhouette suite: seated torso blob detected (upper-half centroid, head-biased Y), high-contrast stripes / thin mic arm / small prop / dark colored decor (spread > 14) all rejected, empty wall null, hard scene cut flagged. _ExprEvaluator gained min()/max() support; content assertions updated to the clamped leaf form.
- Checks run: flutter analyze --no-pub = No issues found; flutter test --no-pub = 399 passed (8 docs/reviews/repro failures remain pre-existing and untouched).
- Limitations: host-side only - no device, no real media, no FFmpeg execution, no ML Kit run; silhouette behavior verified only on synthetic 80x45 RGBA grids; the new transport bar / magnetic timeline / haptics are not exercised by widget tests; real multi-speaker merge quality (0.18 X merge, 4-profile cap) needs on-device validation.
- Status: Implemented - awaiting review.

### 2026-10-28 (4) - OpenCode - Crop-drag accumulation fix + silhouette fallback on present.isEmpty

- Scope: lib/features/auto_reframe/presentation/screens/auto_reframe_screen.dart, lib/core/services/face_detection_service.dart, test/auto_reframe_test.dart. Two real-phone bugs found in the previous batch's feature.
- Bug 1 (crop drag barely moved): _onCropPanUpdate kept _dragOrigin fixed at the onPanStart position and applied each PER-FRAME onPanUpdate delta to that stale origin, so dragging nudged the box by only one frame's delta (~2px) for the entire gesture. Fixed: _dragOrigin is now advanced with the CLAMPED result (clampedX, clampedY) after every step, so deltas accumulate 1:1 across the whole preview. The pure math is extracted as public statics on AutoReframeScreen for testability: clampCenterForAspect (the old _clampCropCenter logic; the state's _clampCropCenter now delegates to it) and dragStepCenter(origin + per-frame px delta -> clamped next center).
- Preview tap rework: removed onDoubleTap and onTapDown from the preview GestureDetector (attaching onDoubleTap alongside onTapUp makes Flutter's gesture arena delay EVERY single tap by ~300ms). A single tap now: selects the detected person when the tap lands within tapLockDistance = 0.12 of their marker (_selectSpeakerNearTap, squared-distance compare, returns false when nothing is that close), otherwise immediately upserts a manual keyframe crop center at the tapped (clamped) position. _lastPreviewTap field and _onPreviewTap removed.
- Bug 2 (silhouette fallback silently skipped): analyzeVideoFaceTrack gated the black-silhouette detector on `if (faces.isEmpty)`, so frames where ML Kit returned ONLY tiny background false-positive boxes (all skipped by the face size filter, leaving `present` empty) never ran the silhouette fallback and held the previous off-center crop. Changed to `if (present.isEmpty)` with an explanatory comment: the fallback now runs whenever no valid person face passed the filter.
- Tests (auto_reframe_test.dart now 44 tests; full suite 402): new 'crop drag accumulation (preview gesture math)' group against AutoReframeScreen.dragStepCenter — a continuous 3-step rightward drag accumulates 0.51/0.52/0.53 (10px per frame of a 1000px preview), a 4-step leftward drag reaches 0.46, and repeated over-edge downward deltas stay exactly at the 0.71875 bottom clamp with no overshoot. Note: exactly one axis is ever free (full-width crop locks X at 0.5, full-height crop locks Y at 0.5), matching innerBoxForFill geometry; test setups choose preview/aspect pairs accordingly.
- Checks run: flutter analyze --no-pub = No issues found; flutter test --no-pub = 402 passed.
- Limitations: host-side only — no device run; tap-to-lock vs tap-to-place feel and the 0.12 proximity radius need on-device validation; drag tests exercise the extracted statics, not the widget gesture wiring itself.
- Status: Implemented - awaiting review.

### 2026-10-28 (5) - OpenCode - Speaker tracking responsiveness, instant cuts, robust silhouette detection

- Scope: lib/core/services/face_detection_service.dart, test/auto_reframe_test.dart. Four real-world bugs: sluggish speaker transitions, scene cuts/silhouette only running when present.isEmpty, silhouette center pulled off-head + medium shots rejected, ML Kit single-face contour bias + weak speech scoring.
- Change 1 (always-on grid + scene cuts): _analysisGrid is now decoded on EVERY sampled frame; isSceneChange runs every frame and clears currentSpeaker = null on a hard cut (0ms delay); prevGridBytes updated at the end of every frame. detectSilhouetteOrMotionSubject also runs on EVERY frame (not only when present.isEmpty), with real face boxes masked out so dark hair/beards/hats are never mistaken for a silhouette. Silhouette gets real activity scoring (head gesture * 3.0 + mask-edge motion * 2.0 + a 0.045 floor for prominent silhouettes >= 8% of frame) so a talking masked speaker beats silent visible faces; when no visible faces exist the silhouette wins automatically.
- Change 2 (unbiased multi-face speech): FaceDetectorOptions now enableContours: false (contours only computed for the single largest face). _updateLipActivity adds classification articulation delta (smilingProbability delta * 1.8) and a direct pixel mouth-region luma delta via the new public pure helper computeMouthRegionDelta (6x4 sub-grid inside x[0.25..0.75]/y[0.58..0.88] of the face, sampled in both curr and prev face boxes so rigid head translation cannot fake mouth motion) * 3.5. _SpeakerTrack.lastMoveDelta tracks per-frame center displacement; passersby (moveDelta > 0.055 with recentActivity < 0.025) have score multiplied by 0.15.
- Change 3 (responsive switching): speakerLockSeconds 1.2 -> 0.5; score = recentActivity*12.0 + areaNorm*0.6 + 0.02*(min(hits,6)/6); _selectSpeaker switches immediately when current is gone (incl. after a cut), or when lockedFor >= 0.5, or instantly when current.recentActivity < 0.012 and best.recentActivity >= 0.028 (best.score > current.score*1.12 + 0.008).
- Change 4 (instant cuts + rock-solid locks): maxKeyframes 60 -> 96; speakerJumpThreshold 0.10 -> 0.075; shotSteadyTolerance 0.12 -> 0.20; the ranges.length*3 relaxation in buildKeyframes REMOVED (adjacent speakers 0.14..0.17 always split); every segment boundary keyframe now flagged isCut: true (including travel segments' first point). silhouetteMinClusterFraction 0.06 -> 0.028 (medium 16:9 shots). detectSilhouetteOrMotionSubject: thin vertical stripes/mic arms stripped before clustering (horizontal run < 3 cells cleared), real face boxes masked out, normX from upper-head/neck band (top .. top+0.38h), normY = top + 0.26h.
- Tests (auto_reframe_test.dart now 47 tests; full suite 406): added 'speaker-switch instant cuts (25+ cuts)' group (26 alternating shots at 0.52/0.68 -> all switches isCut, >=20 cuts), 'silhouette thin-stripe stripping & medium shots' group (thin 1-cell wall molding does not pull normX; ~3.5% medium silhouette detected; computeMouthRegionDelta returns 0 without grids and >0 on mouth change). Existing traveling-speaker test updated for the 0.20 tolerance.
- Checks run: flutter analyze --no-pub = No issues found; flutter test --no-pub = 406 passed.
- Limitations: host-side only - no device run, no real media/ML Kit/FFmpeg; silhouette thin-stripe stripping and face-box masking verified on synthetic grids only; mouth-region delta and passersby penalty need on-device validation.
- Status: Implemented - awaiting review.

### 2026-10-28 (8) - OpenCode - Clamp silhouette region to valid grid indices

- Scope: lib/core/services/face_detection_service.dart, test/auto_reframe_test.dart. RangeError crash introduced when silhouetteRegionX1 was set to 1.0.
- Fix: x0/x1/y0/y1 in detectSilhouetteOrMotionSubject now clamped to 0..width-1 / 0..height-1, preventing gx=80 row-wrap and the resulting RangeError in ceiling-pillar removal that aborted whole-video analysis.
- Silhouette activity block restructured to drop activity immediately to 0.004 when a visible face is actively speaking (0ms delay), instead of capping at 0.005.
- Tests (auto_reframe_test.dart now 54 tests; full suite 412): added full-width grid regression test (ceiling + left/right borders) asserting no RangeError and normW < 0.5. All pass.
- Checks run: flutter analyze --no-pub = No issues found; flutter test --no-pub = 412 passed.
- Limitations: host-side only.
- Status: Implemented - awaiting review.

### 2026-10-28 (7) - OpenCode - Masked-speaker tracking in wide shots and right-edge close-ups

- Scope: lib/core/services/face_detection_service.dart, test/auto_reframe_test.dart. Two remaining bugs from frame-by-frame review.
- Bug 1 (silent visible faces beat masked speaker in wide 3-person shots): silhouette region widened to full horizontal range (0.0..1.0) so right-edge heads aren't clipped; silhouetteActivity now compares maxVisibleFaceActivity of visible tracks: if all visible faces are silent (<0.018) the masked speaker gets an activity floor of 0.055, if any visible face is actively speaking (>=0.018) the masked speaker yields (activity capped at 0.005). computeMouthRegionDelta and _updateLipActivity gained noise-floor deadbands (0.0065 for pixel delta; 0.006 for mouth open/width, 0.015 for smile) so H.264 grain and ML Kit jitter on silent faces produce 0.0.
- Bug 2 (right-edge clipping at t=54s): silhouetteRegionX1 0.98->1.0 (and X0 0.02->0.0); out-of-bounds horizontal neighbors in the 3x3 darkNeighbor count are now treated as dark, so a masked head touching the left/right border is not eroded (darkNeighbors >= 5 still holds).
- Tests (auto_reframe_test.dart now 53 tests; full suite 411): added noise-floor test (<=1 gray level -> 0.0, >=15 gray levels -> >0.02) and right-border silhouette test (gx=70..79, normX > 0.85). All pass.
- Checks run: flutter analyze --no-pub = No issues found; flutter test --no-pub = 411 passed.
- Limitations: host-side only - no device run, no real media/ML Kit/FFmpeg; new deadbands and right-border handling verified on synthetic grids only; on-device validation still needed for multi-speaker scoring and tap/drag feel.
- Status: Implemented - awaiting review.

### 2026-10-28 (6) - OpenCode - Scene-cut-aware analysis, expanded exclusion rects, ceiling-pillar stripping, _enforceBudget cut preservation

- Scope: lib/core/services/face_detection_service.dart, test/auto_reframe_test.dart. Four real-world bugs found frame-by-frame against the multi-camera studio video.
- Bug 1 (fake lip delta across scene cuts): _analysisGrid + isSceneChange now run BEFORE the face loop; cut clears currentSpeaker = null immediately; _associateFace gains allowExisting (passed !cut) and returns null on a cut so a new camera shot never hijacks a previous track; _associateSubject skips non-silhouette tracks. _updateLipActivity's hasPrev is now track.hits > 0 && !cut, and on a cut lastOpen/lastWidth/lastSmile are not diffed (anchor reset), so computeMouthRegionDelta never diffs two different scenes.
- Bug 2 (beard/mic/table false silhouettes): faceBoxes now use an expanded person+desk exclusion rect (x ± 1.45*fw, y0 - 0.45*fh, y1 + 3.20*fh) masking hat/hair/beard/mic/suit/torso/table. Solo close-ups (maxFaceArea >= 0.035) skip detectSilhouetteOrMotionSubject entirely.
- Bug 3 (ceiling pillar pulling normX to 0.58): silhouetteRegion widened to 0.02..0.98; top-down ceiling-pillar removal strips vertical pillars (3-6 cells) seeded at gy 0..3 that connect to horizontal mic arms; normX computed from the upper-head/neck band (top..top+0.30h) weighted by each column's thickness squared, locking onto the thickest vertical head+torso column.
- Bug 4 (masked speaker rejected in wide/medium shots): silhouetteMaxLuma 18->24, silhouetteNeighborhoodLuma 22->28, silhouetteMinClusterFraction 0.028->0.014, silhouetteMinBottomFraction 0.65->0.52, silhouetteMaxTopFraction 0.55->0.65, silhouetteMinHeightFraction 0.22->0.15, silhouetteMinWidthFraction 0.10->0.055. _enforceBudget now preserves cut keyframes (points[i].isCut || dt <= 0.0011).
- Tests (auto_reframe_test.dart now 50 tests; full suite 409): added ceiling-pillar stripping test (normX > 0.72), wide 3-person desk silhouette test (~3.5% / 64 cells / luma 21 detected), expanded excludeRects test (dark jacket/table masked -> null). All prior tests still pass.
- Checks run: flutter analyze --no-pub = No issues found; flutter test --no-pub = 409 passed.
- Limitations: host-side only - no device run, no real media/ML Kit/FFmpeg; new silhouette constants and ceiling-pillar stripping verified only on synthetic grids; expanded exclusion rect and passersby penalty need on-device validation.
- Status: Implemented - awaiting review.
