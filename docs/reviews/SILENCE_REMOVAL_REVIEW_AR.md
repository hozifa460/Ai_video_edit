# مراجعة إزالة السكتات من الفيديو

> أحدث مراجعة 2026-10-22: تصحيح B1 متحقق جزئيًا؛ R5 مستعاد، وبقيت هوية ناتج المعالجة وتداخل Auto وعزل العرض (R1/R3/R4). راجع `CODEX_BATCH_B1_REVISION_REVIEW_AR.md` و`OPENCODE_BATCH_B1_COMPLETION_REQUEST_AR.md`. الدفعة الأولى وSR-06 معتمدتان ضمن نطاقهما السابق؛ لا B2 قبل الاعتماد. قياس الوسائط والأداء غير منفذ، والنص التالي baseline تاريخي.

التاريخ: **2026-10-05** — الحالة: **مراجعة أولية موثقة، لم تُطبق إصلاحات إنتاجية**.

## النتيجة

المسار يعمل نظريًا كاستخراج صوت → كشف → تنقية → تحويل فترات الحذف إلى فترات الاحتفاظ → قص/دمج → معاينة/تصدير. لكنه غير جاهز لاعتماد عبارة «حماية الكلام وتزامن مثالي» دون معالجة البنود أدناه واختبارات وسائط فعلية. أخطر ما ظهر: دمج الكلام بين السكتات ضمن الحذف، توسيع الحذف بإعدادات padding، اعتماد مدة الصوت بدل الفيديو، وحالة مشتركة لا ترتبط بملف/عملية.

هذا تقرير بالمشكلات التي أمكن تحديدها ضمن الفحص، وليس ضمانًا بحصر كل عيب محتمل. **مؤكد بالكود** يعني أن المنطق/الاستدعاء ظاهر؛ **معاد إنتاجه** يعني تشغيل مثال فعلي على دالة المشروع؛ **خطر يحتاج جهازًا** يعني أن النتيجة على الوسائط لم تُشغّل هنا.

P1 = فقد محتوى أو نتيجة خاطئة أو فشل وظيفة مهمة؛ P2 = عطل مشروط/سلوك مضلل/مورد لا يُدار؛ P3 = قابلية صيانة أو UX أقل إلحاحًا. لا توجد واقعة P0 مثبتة.

## نطاق التحقق

قرأنا مسار `silence_detector` بكامل طبقاته، `audio_processing`، `video_processing`، `preview`، `export`، وكذلك home/router/file utilities ومكونات مشتركة مؤثرة. لم يُشغّل plugin FFmpeg على Android/iOS ولم يُصدر فيديو أصلي؛ مراجعة الأوامر مدعومة بتوثيق FFmpeg، مع فصل المخاطر التي تتطلب قياسًا.

| تحقق | النتيجة |
|---|---|
| `flutter test --no-pub --reporter expanded` | 81 ناجحًا؛ اختبارات المشروع السابقة |
| `flutter analyze --no-pub` | No issues found |
| أمثلة المراجعة المنفصلة | 7 ناجحة؛ نجاحها يثبت السلوك المعيب الحالي |
| native A/V وواجهة جهاز | لم يُنفّذ |
| فحص diff تاريخي | غير متاح؛ هذه النسخة ليست Git repository |

أمثلة التحقق: `docs/reviews/repro/silence_characterization_test.dart`. شغّلها صراحة:

```powershell
flutter test --no-pub docs/reviews/repro/silence_characterization_test.dart --reporter expanded
```

لا تُدرج توقعاتها الحالية في مجموعة اختبارات سلامة المنتج؛ يجب تحويلها إلى assertions للسلوك الصحيح عند الإصلاح.

## سجل المشكلات

### SR-01 — P1 — دمج السكتات يحذف الكلام الواقع بينها

**الموضع:** `lib/features/silence_detector/data/datasources/ffmpeg_silence_datasource.dart:72`، و`data/repositories/silence_detector_repository_impl.dart:42` و`:81` تحت نفس feature.

**الدليل:** datasource يدمج gap حتى 150ms قبل VAD، ثم repository يستخدم `minSilenceDuration` كـmaxGap بعد VAD. مثال معاد إنتاجه: صمت `[1,2]` و`[2.2,3]` يصبح `[1,3]` عند الحد الافتراضي 0.25؛ الـ200ms بينهما تُحذف ولو كانت كلمة. عند اختيار minimum=5s يمكن أن يمتد دمج repository عبر كلام مدته عدة ثوانٍ. تنقية VAD لا تصلح ذلك لأنها تسبق هذا الدمج الثاني.

**الإصلاح:** union للتداخل/التماس فقط؛ أي سياسة لحذف speech islands يجب أن تكون ميزة منفصلة تعتمد تصنيفًا واضحًا، لا min silence. **القبول:** بقاء `[2,2.2]` محفوظًا؛ رفع minSilenceDuration لا يزيد طول الكلام المحذوف؛ اختبار VAD on/off.

### SR-02 — P1 — الـpadding يوسّع منطقة الحذف إلى الكلام

**الموضع:** `lib/features/silence_detector/data/repositories/silence_detector_repository_impl.dart:102`–`:108`.

**الدليل المعاد إنتاجه:** `[1,2]` مع before/after=0.15 يصير `[0.85,2.15]`. إذا المقصود حماية أطراف الكلام فالعلامتان عكس المطلوب؛ حتى إذا كان المقصود توسعة الصمت، لا يوجد تحذير أو تحقق speech قبل حذف المحتوى المجاور. هامش الحماية 50ms المذكور في PROJECT_MAP غير موجود.

**الإصلاح:** اعتمد عقدًا واضحًا: padding المحمي يُبقي جزءًا داخل حدود السكتة، بحيث مجال الحذف لا يخرج عن الصمت المؤكد. سمِّ توسعة الحذف إن أريدت كإعداد منفصل واضح. **القبول:** زيادة الحماية لا تنقص الكلام المحفوظ، واختبار نهاية كلمة/بداية كلمة في صوت حقيقي.

### SR-03 — P2 — التداخل بعد padding يفسد الإحصاءات وعقد القص

**الموضع:** `silence_detector/data/repositories/silence_detector_repository_impl.dart:100`، `silence_detector/domain/providers/silence_detection_provider.dart` في `totalSilenceDurationProvider`، `video_processing/data/services/ffmpeg_cutting_service.dart:68`.

**الدليل المعاد إنتاجه:** `[1,2]`, `[2.6,3.5]` مع padding=0.5 ينتجان `[0.5,2.5]`, `[2.1,4]`. الجمع يعطي 3.9s بينما union=3.5s. لا توجد normalization نهائية. مجموع الواجهة قد يتجاوز الحذف الفعلي، وقد يعطي مدة معالجة سالبة في حالات كثيرة التداخل. complement يعتمد ترتيب ونهايات المدخلات دون تطبيع.

**الإصلاح:** canonical intervals مشتركة للحساب/الرسم/القص، وقياس union لا sum الخام. **القبول:** إحصاءات متطابقة مع مجموع kept intervals؛ 0≤removed≤duration؛ nested/overlap/unsorted inputs.

### SR-04 — P1 — السكتات من الفيديو السابق قابلة للاستخدام في الفيديو التالي

**الموضع:** `silence_detector/domain/providers/silence_detection_provider.dart:11`، `silence_detector/presentation/editor_screen.dart:40`–`:90`, `:121`, `:479` وما بعدها؛ `video_import/presentation/home_screen.dart:496`.

**الدليل بالكود:** provider عام، لا file identity ولا reset عند دخول/خروج المحرر؛ بعد تهيئة ملف B وأثناء كشفه، `hasSegments` قد يأتي من A وPreview/Export لا يتعطلان بسبب `_isDetecting`. فشل كشف B يبقي نتيجة A. عند نجاح استخراج الصوت لـB يمكن بدء القص بفترات A.

**الإصلاح:** session/project state keyed بالملف مع إبطال نتائج الملف السابق، وgeneration id للطلبات. **القبول:** A طويل ثم B قصير؛ أثناء detection والفشل لا يظهر زر تصدير لنتيجة A ولا يطبق أي interval خارج B.

### SR-05 — P1 — المدة المرجعية مرتبطة بالـwaveform بدل الفيديو

**الموضع:** `silence_detector/presentation/editor_screen.dart:112`, `:186`, `:274`، `audio_processing/data/repositories/audio_processor_repository_impl.dart` عند حساب `totalSamples / sampleRate`.

**الدليل:** إذا فشل تحليل waveform تصبح المدة 0، ثم padding يحذف كل النتائج بالـclamp؛ هذا الجزء معاد إنتاجه. وإذا كان الفيديو 10s والصوت 8s فـ`_buildSpeechSegments` لا يحتفظ بذيل الفيديو بعد 8s عند وجود قص؛ كما لا يوجد تحويل لإزاحة بداية audio عن video timeline.

**الإصلاح:** probe موحد يحتفظ بمدة الفيديو وstart_time لكل stream؛ waveform ملحق عرض لا مصدر حقيقة زمني. **القبول:** video أطول/أقصر من audio، audio متأخر 500ms، فشل waveform فقط لا يمنع الكشف والقص الصحيحين.

### SR-06 — P2 — المرحلة الثانية تتجاوز الحد الأدنى الذي اختاره المستخدم

**الموضع:** `silence_detector/data/datasources/ffmpeg_silence_datasource.dart:20`–`:32`.

**الدليل:** pass2 ثابت 0.3s مهما كان min silence. باختيار 2s، صمت عميق مدته 0.4s قد يأتي من pass2 ويُحذف لأن merge هو اتحاد ولا توجد إعادة فلترة بالحد المختار. وصف sensitive مضلل أيضًا: -10dB يجعل معيار الصمت أشد انخفاضًا، لا يلتقط ضوضاء أعلى.

**الإصلاح:** احترم الحد المختار في جميع المراحل أو اعرض وضع fine detection صريحًا؛ طبّق المعنى المحدد للمدة على النتائج. **القبول:** فترات 0.29/0.31/1.99/2.01s مع min=2s وVAD off ثم on.

### SR-07 — P2 — Auto وتعديل الإعدادات لا يُبطلان النتيجة القديمة

**الموضع:** `silence_detector/presentation/editor_screen.dart:148`–`:173` و`widgets/detection_settings_panel.dart` callbacks؛ provider params منفصل عن segments.

**الدليل:** Auto يحدث threshold ويعرض نجاحًا دون `_detectSilence`؛ sliders/toggles تحدث params فقط. يمكن تصدير segments من الإعدادات القديمة بينما الشاشة تعرض الإعدادات الجديدة. زر الكشف اليدوي موجود، لكن لا توجد حالة stale أو منع تصدير توضح وجوب استعماله.

**الإصلاح:** تتبع params revision؛ إعادة كشف تلقائية debounce أو زر Apply وتعطيل التصدير للنتيجة القديمة. **القبول:** بعد Auto/threshold/padding/VAD يظهر pending ويصبح التصدير مرتبطًا بإعدادات مكتملة الكشف فقط. Smart Zoom يعاد render له دون إعادة كشف صوت إذا لم يؤثر على intervals.

### SR-08 — P2 — VAD ينهار على ملفات قصيرة صالحة

**الموضع:** `silence_detector/data/services/vad_service.dart:48`–`:49`.

**الدليل المعاد إنتاجه:** WAV PCM16 mono 16kHz مدته 100ms يعطي 5 frames؛ `(5*0.90).round()` يساوي 5 وهو خارج قائمة طولها 5. الحالات 1–5 frames معرضة لهذا. تصل الحالة من UI إذا خُفّض min silence؛ الافتراضي 250ms يجعلها أقل شيوعًا.

**الإصلاح:** quantile index محدود `[0,n-1]` وتعامل واضح مع عدد frames الصغير. **القبول:** 0/1/2/5/6 frames ومدد تحت الحد الأدنى؛ لا RangeError.

### SR-09 — P2 — Auto يقرأ WAV بإزاحة ثابتة وVAD لا يحلل RIFF بشكل صحيح

**الموضع:** `silence_detector/data/services/adaptive_threshold_service.dart:15`–`:22`؛ `vad_service.dart:89`–`:100`.

**الدليل بالكود:** Auto يتخطى 44 byte بصرف النظر عن chunks؛ WAV ذو LIST/JUNK أو fmt موسّع يقرأ metadata كصوت ويزيح نافذة التحليل. VAD يبحث عن بايتات كلمة data في أي مكان، ولا يلتزم chunk sizes/padding ولا data length؛ fallback 44 قد يتجاوز حجم ملف مبتور.

**الإصلاح:** RIFF parser صغير مشترك مع validation PCM format/channel/rate/data bounds أو استخراج raw PCM بعقد صريح. أغلق handle في finally. **القبول:** WAV عادي، extra chunks، كلمة data داخل metadata، odd chunk padding، ملف أقصر من44؛ خطأ واضح دون crash/تسرب handle.

### SR-10 — P1 — القص ذو الجزء الواحد لا يضمن دقة إطار

**الموضع:** `video_processing/data/services/ffmpeg_cutting_service.dart:108`–`:140`.

**الدليل:** `_simpleCopy` يستخدم seek قبل input مع `-c:v copy` بينما الصوت يعاد ترميزه. هذه ليست نفس دقة trim/atrim المستخدمة عند تعدد الأجزاء. يمكن أن تبقى صور من قبل القطع المطلوب تبعًا للـkeyframes؛ أثر A/V على ملفات المستخدم يحتاج native test. هذا استنتاج من الأمر ومن [توثيق FFmpeg للـseek](https://ffmpeg.org/ffmpeg.html#Main-options)، لا نتيجة تجربة فيديو هنا.

**الإصلاح:** استخدم المسار الدقيق نفسه في حالة segment واحد؛ إن أُبقي fast copy فيكون وضعًا معلنًا مع tolerance وfallback codec. **القبول:** رأس صامت ينتهي بين keyframes بفيديو long GOP مع flash/beep مرجعي؛ start/end ودقة الصوت والصورة ضمن tolerance موثق.

### SR-11 — P2 — تقدم التصدير يخلط seconds بـmilliseconds

**الموضع:** `lib/features/video_processing/data/repositories/video_processor_repository_impl.dart:101`، داخل `exportVideo` عند `double.tryParse(durationStr)?.round()`؛ والخدمة `ffmpeg_cutting_service.dart:38`.

**الدليل:** FFprobe duration=120.5s يصبح `videoDurationMs=121` بدل120500، ثم statistics بالـms تُقسم عليه، فيظهر100% مبكرًا. importer يحتوي تحويلًا صحيحًا يمكن توحيده.

**الإصلاح والقبول:** helper موحد؛ 120.5s→120500ms و60250ms→50%. أضف معالجة null/NaN/Infinity والقيم غير الموجبة.

### SR-12 — P2 — الإلغاء لا يلغي المهمة وقد ينتهي بـCompleted

**الموضع:** `video_processing/domain/providers/processing_provider.dart` في `cancel()` وعودة `startProcessing`؛ `video_processing/presentation/processing_screen.dart` زر Cancel.

**الدليل المعاد إنتاجه:** `cancel` يغير enum فقط؛ repository يواصل العمل وعند نجاحه تصبح الحالة completed. تدفق Editor الفعلي يعرض dialog غير قابل للإغلاق دون زر إلغاء، فلا يستفيد أصلًا من زر شاشة Processing المنفصلة.

**الإصلاح:** session id/cancel token يمر عبر layers؛ cancelled terminal للـgeneration الحالي، لا قبول نتيجة متأخرة، وتنظيف output غير المكتمل. **القبول:** cancel أثناء detection/render/export؛ لا نجاح بعد الإلغاء ولا إلغاء لعملية أخرى.

### SR-13 — P2 — سباقات طلبات ودورة حياة الشاشات

**الموضع:** `silence_detector/presentation/editor_screen.dart:121`, `:148`، `detection_settings_panel.dart:38`، `preview/presentation/preview_screen.dart` في `_initPlayers`.

**الدليل:** Auto متاح أثناء الكشف ويغير `_isDetecting` نفسه؛ يمكن أن يعيد false قبل انتهاء كشف آخر، ويسمح بطلبات متداخلة. لا request id، ولا mounted قبل `ref.read` بعد await detection. Preview ينشئ controllers بعد awaits ثم `setState` بلا mounted عند النجاح؛ dispose المبكر يمكن أن يترك controller جديدًا بلا مالك.

**الإصلاح:** state machine للعمليات، latest-request-wins، mounted/ownership checks بعد awaits، وتنظيف controllers المحلية قبل إسنادها. **القبول:** Auto متعدد بسرعة، تغييرات ثم رجوع، فتح/إغلاق أثناء init؛ لا stale overwrite ولا use-after-dispose أو controllers متروكة.

### SR-14 — P2 — مراقبة تقدم FFmpeg عالمية وتتداخل بين العمليات

**الموضع:** `video_processing/data/services/ffmpeg_cutting_service.dart:36`–`:45`؛ استعمالات `enableStatisticsCallback` الأخرى في المشروع.

**الدليل:** callback عالمي يُستبدل ثم يُمسح، بلا فلترة session وبلا finally إذا رمى execute. الإلغاء غير الحقيقي يزيد احتمال بقاء عمليات بالتوازي. قد يصل progress لمهمة أخرى أو يُمسح callback ما زال مطلوبًا.

**الإصلاح:** statistics callback لكل session في executeAsync، أو منسق jobs مع session filtering. **القبول:** مهمتان متداخلتان، انتهاء الأولى لا يوقف تقدم الثانية، failure يعيد الموارد إلى وضع سليم.

### SR-15 — P2 — PCM وoutputs المؤقتة لا تُنظّف في دورة عمل السكتات

**الموضع:** `audio_processing/data/repositories/audio_processor_repository_impl.dart` في `extractAudio`؛ `silence_detector/presentation/editor_screen.dart:344`؛ `video_processing/data/repositories/video_processor_repository_impl.dart` في `processVideo`.

**الدليل:** `dispose` يتخلص من players فقط، وWAV المستخرج وprocessed MP4 لا يُحذفان عند الخروج أو إعادة المعاينة. output فاشل جزئيًا قد يبقى. raw الخاص بالـwaveform يُنظَّف بالفعل فلا يُنسب له نفس العيب. PCM16 mono16kHz وحده ≈115.2MB لكل ساعة قبل حجم الفيديو الناتج.

**الإصلاح:** job temp directory ودورة ملكية تبقي المعاينة حتى انتهاء المستهلك ثم تنظيف finally/dispose مناسب؛ لا تمس المصدر أو export النهائي. **القبول:** إعادة preview عشر مرات، خطأ FFmpeg، خروج أثناء extraction؛ يبقى فقط ما له مالك حي.

### SR-16 — P2 — VAD على الخيط الرئيسي وذاكرة كاملة للملف

**الموضع:** `silence_detector/data/services/vad_service.dart:19`–`:79`، و`silence_detector/presentation/widgets/waveform_viewer.dart` في `_drawWaveform`؛ `silence_timeline.dart` بناء القائمة.

**الدليل:** قراءة WAV كاملًا ثم loops لكل sample وفرز energies داخل isolate الواجهة؛ async I/O لا ينقل حسابات Dart إلى isolate آخر. التكلفة تزيد بطول الفيديو. رسم كل عينة يستخدم `segments.any`، وجميع عناصر السكتات تُبنى دفعة واحدة داخل SingleChildScrollView.

**الإصلاح:** streaming/windowed analysis في isolate، cancellation/progress، lookup للفترات أو sweep، وقائمة كسولة. **القبول:** ملفات 30/60/120 دقيقة ومئات/آلاف السكتات على جهاز ضعيف؛ قياس peak RAM/frame times وليس مجرد انتهاء المهمة.

### SR-17 — P2 — تشغيل صوت المعاينة المخفي واحتمال استمرار صوت المحرر

**الموضع:** `preview/presentation/preview_screen.dart` في `_buildComparisonToggle`؛ `silence_detector/presentation/editor_screen.dart` في `_previewResult`/`_processAndExport`.

**الدليل:** تبديل Original/Processed يغير bool فقط ولا pause للـcontroller المخفي. الانتقال من المحرر لا يوقف source player صراحة. لذلك إذا بدأ المستخدم التشغيل قبل التبديل/التنقل، يوجد مسار لاستمرار playback غير المرئي؛ التأكيد السمعي يحتاج جهازًا.

**الإصلاح:** pause عند الإخفاء/تغيير route؛ حدد مقارنة مرتبطة بخريطة original→processed time، لأن seek لنفس الثانية بعد الحذف ليس مقارنة صحيحة. **القبول:** صوت لاعب واحد فقط، أثناء toggle/رجوع/دخول export، واختبار position mapping.

### SR-18 — P2 — التصدير لا يرتبط صراحة بالناتج الذي عاينه المستخدم

**الموضع:** `preview/presentation/preview_screen.dart` في كلا زري Export؛ `silence_detector/presentation/editor_screen.dart:330`؛ `export/presentation/export_screen.dart:47`.

**الدليل:** route يمرر originalPath بينما ExportScreen يفضل global `processingState.outputPath`. إذا تغير provider أو reset أو وصل job آخر، مصدر التصدير يتغير؛ fallback هو الأصل غير المعالج. هذا ضعف تعاقد مثبت، أما تصدير ملف خاطئ فعليًا فيتطلب تسلسل تغير state.

**الإصلاح:** مرر immutable processed asset/job id، ولا fallback إلى الأصل في export خاص بإزالة السكتات. **القبول:** غير global output بعد فتح Preview؛ يجب أن يصدر الملف الذي عاينه المستخدم أو يطلب إعادة توليده إذا فقد، لا أصلًا أو نتيجة أخرى.

### SR-19 — P2 — mergeCloseSegments يصغّر interval عند الاحتواء

**الموضع:** `silence_detector/data/repositories/silence_detector_repository_impl.dart:84`.

**الدليل المعاد إنتاجه:** `[1,5]` مع `[2,3]` يصيران `[1,3]` بدل `[1,5]`؛ النهاية تستبدل بلا max. datasource الحالي غالبًا يزيل هذا الشكل قبل وصوله، لذلك العيب في العقد العام ومقاومته للمدخلات وليس ادعاء أنه يظهر في كل كشف.

**الإصلاح:** max(end) مع validation مشتركة. **القبول:** contained/equal/overlap/unsorted واختبارات invariants.

### SR-20 — P2 — فشل التهيئة يترك loading دائمًا

**الموضع:** `silence_detector/presentation/editor_screen.dart:92`–`:101` وشرط `_isInitialized` في build؛ `export/presentation/export_screen.dart` في `_generateSavePath`.

**الدليل:** catch player/init يعرض snackbar فقط دون error state، والـbody يبقى spinner. `_generateSavePath` async من initState بلا handling للفشل؛ `_savePath=null` يجعل الضغط بلا نتيجة. الملف بلا audio يُعرض له extractor error ثم لا يمكن الكشف، بدل مسار رسالة مفهوم قبل المعالجة.

**الإصلاح:** حالات loading/ready/noAudio/error واضحة وزر retry/back؛ validation streams قبل extraction، وفشل مجلد التصدير ظاهر. **القبول:** corrupted/no-audio/permission denied/path provider failure لا تبقي loading أو زرًا بلا فعل.

### SR-21 — P2 — الملف الصامت بالكامل يتحول إلى خطأ FFmpeg مبهم

**الموضع:** `video_processing/data/services/ffmpeg_cutting_service.dart:100`، وrepository عند `result==null`.

**الدليل:** بعد إزالة كل المدة لا توجد speechSegments فتعود null ثم `FFmpeg processing returned no output` رغم أنها حالة محتوى متوقعة. يمكن إعادة السيناريو بعد تجنب VAD/معالجة حدود الكشف.

**الإصلاح:** نتيجة typed مثل noSpeechRemaining، مع خيار المستخدم الاحتفاظ بالأصل أو تعديل settings؛ لا تبدأ encode فارغًا. **القبول:** all silence، no silence، tiny remainder، zero duration؛ رسائل مميزة ولا output تالف.

### SR-22 — P2 — معنى Original وإعادة الترميز المزدوج غير واضحين

**الموضع:** `video_processing/data/services/ffmpeg_cutting_service.dart:49`–`:60`, `:199`, `:297`؛ `export/presentation/export_screen.dart` وصف quality.

**الدليل:** concat يستخدم libx264 دون CRF/preset صريح في المسار الأول، وكل quality تغيّر AAC bitrate فقط. editor يرمّز الصوت192k ثم export يعيد AAC ثانية حتى Original. الواجهة توضح bitrate تحت الاختيار، لكن كلمة Original لا تعني حفظ جودة الفيديو المصدر أو عدم خسارة الصوت.

**الإصلاح:** عقد جودة صريح، إعداد video encode معلوم، وتصدير من job recipe مباشرة أو audio copy إذا الناتج مطابق للملف المطلوب. **القبول:** probe actual codecs/bitrate؛ لا re-encode غير لازم بعد preview؛ لا ادعاء lossless للمسار الذي يعيد الترميز.

### SR-23 — P2 — اختيار audio stream ليس موحدًا بين الكشف والقص

**الموضع:** `audio_processing/data/repositories/audio_processor_repository_impl.dart` أمر extractAudio بلا map؛ `video_processing/data/services/ffmpeg_cutting_service.dart:179` وما بعده graph بـ`[0:a]`؛ metadata importer يحتفظ بآخر audio stream في loop.

**الدليل:** مراحل مختلفة تترك اختيار stream ضمنيًا أو تستخدم أول audio filter input. فيديو به تعليق صوتي ومسار موسيقى قد يُحلّل مسارًا ويصدر آخر؛ هذه مخاطرة مشروطة بملف متعدد المسارات. [توثيق اختيار streams](https://ffmpeg.org/ffmpeg.html#Stream-selection) يوضح الاختيار التلقائي عند غياب map.

**الإصلاح:** track index صريح محفوظ في media/session ويستخدم في extraction/render/export؛ policy للـadditional audio/subtitles. **القبول:** ملف first-track music وsecond-track speech، قنوات/default dispositions مختلفة؛ اختيار المستخدم يحكم جميع المراحل.

### SR-24 — P2 — VAD الحالي لا يحقق وصف «Filter non-speech noise»

**الموضع:** `silence_detector/data/services/vad_service.dart:47`–`:82`؛ subtitle في `detection_settings_panel.dart`.

**الدليل:** يعتمد الطاقة فقط ويستبعد silence candidates المتقاطعة مع speech energy؛ لا ينشئ فترات جديدة لمروحة/موسيقى لم يكتشفها silencedetect أصلًا. إشارة ضوضاء وكلام بالطاقة نفسها لا يميز بينهما هذا النموذج. overlap صغير قد يمنع إزالة سكتة طويلة بالكامل.

**الإصلاح:** وضّح أنه energy gate مساعد، أو نفذ speech detector مع تقييم مناسب؛ استقطاع مناطق الكلام من candidates بدل إسقاط interval كاملًا إذا كان ذلك عقد المنتج. **القبول:** موسيقى/مروحة/همس/تنفس/كلام منخفض، ومقاييس حذف كلام/صمت متروك على عينات عربية متنوعة.

## مخاطر إضافية تحتاج تحققًا أو قرارًا منتجيًا

هذه ليست نتائج runtime مؤكدة ولا تضاف إلى عدد الـ24 أعلاه:

| ID | الخطر والموضع | الاختبار/القرار |
|---|---|---|
| R-01 | SmartZoom يعيد scale ثم crop تقريبيًا وsetsar=1 للأجزاء المتناوبة فقط | portrait/odd dimensions/non-square SAR؛ normalize dimensions وSAR لجميع الأجزاء. [concat يحتاج توافقًا](https://ffmpeg.org/ffmpeg-filters.html#concat) |
| R-02 | raw hard cuts بلا micro-fade في الصوت | listen/measure discontinuities عند الحذف؛ أضف fade محكومًا دون تغيير الزمن أو إتلاف بداية الحرف |
| R-03 | graph يتسع خطيًا بعدد cuts، وfallback يعيد نفس graph أساسًا | 100/1000/5000 cuts؛ حدود resources وقدرة cancellation؛ chunk strategy إذا لزم |
| R-04 | نجاح output يُفحص بوجود الملف فقط، دون streams/duration/decode | FFprobe وفك جزء فعلي، empty/truncated output، VFR/offsets؛ حدود A/V قابلة للقياس |
| R-05 | padding/threshold settings لا تُحفظ، ولا draft/undo لفترات السكتات | حدّد هل persistence مطلوبة؛ لا تخلط وجود Shorts drafts مع دعم silence drafts |
| R-06 | parser يعتمد نص logs وstart كامل قابل لـdouble.tryParse وgetAllLogsAsString | fixtures من build المثبت: trailing silence، scientific/negative timestamps، callbacks المتأخرة؛ لا تفترض فشلًا حاليًا بلا log حقيقي |
| R-07 | `useRms` غير مستخدم و`:m=1` ليس RMS | ملاحظة صيانة: m هو per-channel وفق [silencedetect](https://ffmpeg.org/ffmpeg-filters.html#silencedetect)، فلا تستخدمه مستقبلًا لتفعيل RMS |
| R-08 | FileUtils قد يختار documents لكن الواجهة تقول Downloads، ومسح media غير منتظر | Android حديث/iOS جهاز فعلي؛ مسار ظاهر صحيح وإتاحة المشاركة/المعرض عند الطلب |
| R-09 | أوامر FFmpeg مبنية كسلاسل بمسارات مقتبسة فقط | أسماء Unicode/مسافات/quotes على المنصات المدعومة؛ استخدم argument arrays/escaping الخاص بالـplugin، ولا تصنفه shell injection دون إثبات استعمال shell |
| R-10 | downmix إلى mono قبل الكشف قد يلغي قنوات ذات طور معاكس | dual-channel phased fixture؛ اختيار/تجميع قنوات يحفظ النشاط بدل اعتبار الصوت صمتًا |

## حدود UX ملحوظة

- قائمة السكتات تعرض توقيتًا بدقة ثوانٍ رغم sliders بالدقائق الفرعية؛ يصعب مراجعة حدود100ms. أضف milliseconds وحدود قابلة للاستماع/التعديل.
- حذف العنصر من قائمة السكتات يعني الاحتفاظ به في الناتج؛ icon سلة وحده قد يلتبس على المستخدم. اجعل الوصف «استبعاد من الحذف/الاحتفاظ بهذا المقطع».
- BreathingProtection قواعد مدة فقط، لا كشف تنفس؛ من0.2 إلى0.3s يحذف70%، وفوق0.3s يحذفها كاملة. الاسم أوسع من الضمان الفعلي؛ اختبر الإيقاع الطبيعي قبل تغيير النسب.
- progress قد يرجع من0.1 إلى0.01 ومن إحصاءات قرب1 إلى0.9؛ والجزء الواحد بلا progress حقيقي. أصلح mapping للمراحل بعد SR-11/SR-14.

## ترتيب المعالجة المقترح

1. **سلامة المحتوى:** SR-01/02/03/05/19، مع تعريف عقود الفترات والمدة وstream المختار SR-23.
2. **صحة حالة المستخدم:** SR-04/07/12/13/14/18، session immutable وinvalidation وإلغاء حقيقي.
3. **كاشف قابل للاختبار:** SR-06/08/09/24، parser وPCM model واضحة، dependency injection.
4. **القص والتصدير:** SR-10/11/20/21/22، ثم R-01/R-04/R-08 وnative fixtures.
5. **الأداء والتجربة:** SR-15/16/17 وبقية المخاطر وUX.

كل SR في هذا الإصدار حالته **Open**. مرجع تسليم عملي واختبارات القبول المجمعة: `OPENCODE_HANDOFF_AR.md`.

## ملاحظات للمراجع التالي

- لا تنقل «81 tests pass» إلى شهادة سلامة السكتات؛ أغلب التغطية الحالية cutter/audio command builders.
- لا تعالج كل شيء بتغيير thresholds؛ فقدان الكلام سببه أيضًا merge/padding/timebase/state.
- لا تخلط خدمات الصمت الثلاث: video silence remover وShorts smartAudio وProfessionalAudioEditorService.
- لا تثبت صلاحية native FFmpeg من `flutter analyze` أو flutter unit tests؛ native encoding لم يعمل هنا.
- احتفظ بمعرّفات SR وتاريخ baseline، وأضف نتيجة كل fix واختباره ومنصة تشغيله.
