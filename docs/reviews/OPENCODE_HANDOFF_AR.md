# تسليم للمطور OpenCode — إصلاح إزالة السكتات

> أحدث مراجعة 2026-10-22: تصحيح B1 متحقق جزئيًا؛ R5 مستعاد، وبقي R1/R3/R4. التقرير `CODEX_BATCH_B1_REVISION_REVIEW_AR.md` والطلب الحالي `OPENCODE_BATCH_B1_COMPLETION_REQUEST_AR.md`. لا B2 قبل الاعتماد. الدفعة الأولى وSR-06 معتمدتان ضمن نطاقهما السابق؛ قياس الوسائط والأداء غير منجز. التعليمات التالية سجل التسليم الأصلي.

ابدأ بقراءة `AGENTS.md` و`PROJECT_MEMORY.md` ثم `docs/reviews/SILENCE_REMOVAL_REVIEW_AR.md`. حافظ على معرّفات SR في شرحك. هذه مراجعة لحالة2026-10-05؛ افحص التغيرات قبل الاعتماد على أرقام السطور. لا توجد Git metadata في baseline المحلي.

## تعليمات المستخدم الملزمة للتعاون والذاكرة

اقرأ `PROJECT_MEMORY.md` من القرص قبل كل جولة عمل أو مراجعة، حتى لو قرأته في جلسة سابقة. بعد كل مراجعة حدّثه بالنتائج والتاريخ والنطاق والاختبارات الفعلية والقيود والخطوة التالية، حتى لو لم تغير كودًا. ينطبق ذلك على OpenCode وCodex وأي نموذج لاحق.

OpenCode هو المنفذ لهذه الدفعة، وCodex يراجع التغييرات بعدها. بعد التنفيذ حدّث وصف المشروع المتغير وسجل المتابعة في الذاكرة، وسجّل البنود **«منفذ — بانتظار المراجعة»** مع الأدلة. لا تعلنها معتمدة نهائيًا قبل المراجعة المستقلة، ولا تمح النتائج السابقة أو ملفات baseline. يقرأ Codex الذاكرة مجددًا قبل المراجعة ثم يحدثها بما تحقق منه وما بقي مفتوحًا.

نفذ الدفعة الأولى فقط ثم سلّم تقريرًا محفوظًا في `docs/reviews/OPENCODE_BATCH_01_RESULT_AR.md` يتضمن الملفات المعدلة ومعرفات SR والاختبارات والنتائج والقيود. لا تنتقل تلقائيًا إلى الدفعات التالية قبل مراجعة هذه الدفعة.

## المهمة الأولى المقترحة

أصلح **SR-01, SR-02, SR-03, SR-05, SR-19** كدفعة مترابطة لسلامة الفترات. المطلوب حماية الكلام وتوحيد المدة دون إعادة تصميم جميع الشاشات.

1. استخرج interval normalization/complement إلى دوال pure typed قابلة للاختبار. reject القيم غير finite والمدد غير الصالحة، clamp للحدود، sort وmerge للتداخل فقط، ثم حساب kept intervals.
2. افصل `minSilenceDuration` عن أي سياسة دمج؛ لا تملأ gap بين سكتتين تلقائيًا لمجرد قصره.
3. عرّف padding كمساحة محفوظة للكلام؛ لا يوسع removal خارج الصمت المؤكد. اختبر نقطة لمس interval وانعدام طوله بعد الحماية.
4. اجعل video timeline/probed duration مصدر الحقيقة؛ فشل waveform لا يعيد duration=0. سجّل stream timing بدل فقده عند extraction إذا كان source offset غير صفري.
5. اجعل الإحصاءات والمعاينة والتصدير تقرأ نفس normalized removal plan. حافظ على الصوت والصورة في نفس kept segments.
6. أضف correctness tests داخل `test/` وحوّل أمثلة characterization المقابلة إلى اختبارات تؤكد الإصلاح أو أرشفها بوضوح؛ لا تُبق توقع السلوك المعيب كهدف نجاح.

## الدفعات التالية

| دفعة | المشاكل | نتيجة مطلوبة |
|---|---|---|
| B — ملكية الحالة | SR-04/07/12/13/14/18 | job id، media identity، immutable recipe، stale results ممنوعة، إلغاء session حقيقي |
| C — الكشف | SR-06/08/09/24 | threshold/min موحدان، PCM parser صحيح، short frames، سلوك VAD موصوف ومختبر |
| D — render/export | SR-10/11/20/21/22/23 | قص دقيق موحد، stream صريح، progress صحيح، حالات خطأ واضحة، codec validation |
| E — الموارد/UX | SR-15/16/17 + R-01..R-10 | تنظيف job files، قابلية إلغاء، أداء طويل، لاعب مرئي واحد، device validation |

## اختبارات قبول ضرورية

| Fixture | ما يجب إثباته |
|---|---|
| صمت `[1,2]` و`[2.2,3]` وبينهما كلام | الاحتفاظ بـ200ms، حتى عند زيادة min silence |
| padding 0/50/150/500ms | لا يزداد الكلام المحذوف بزيادة الحماية؛ intervals سليمة |
| overlap/nesting/unsorted/NaN/Infinity | رفض أو normalize حتمي؛ no negative duration/no duplicate frames |
| فيديو10s وصوت8s | لا يُقص ذيل الصورة لمجرد انتهاء الصوت |
| audio start offset +500ms | قرار الصمت والقص على نفس video timeline |
| فشل waveform extraction | لا تتحول metadata الصحيحة إلى مدة0 |
| min=2s وسكتة0.4s | جميع passes تحترم العقد المختار |
| WAV0/1/2/5/6 frames + LIST/JUNK | لا RangeError، data section صحيحة |
| no audio / all silent / no silence | رسالة ونتيجة typed مفهومة، بلا spinner دائم أو encode فارغ |
| A ثم B أثناء detection / إغلاق الشاشة | لا stale segments أو ref بعد dispose |
| Auto/sliders أثناء الكشف | آخر settings فقط يمكن تصديرها، نتيجة قديمة لا تُعرض كجديدة |
| cancel أثناء native session / بين مراحل | cancelled لا تصبح completed، ملفات جزئية تنظف |
| مهمتان متداخلتان | callbacks/progress/output لا تتداخل |
| long GOP cut بين keyframes | precise mode يعطي نقطة قص ضمن tolerance المحدد |
| فيديو بمسارين صوتيين مختلفين | stream المختار نفسه في detection/render/export |
| VFR29.97، portrait، non-square SAR، odd dims | concat/zoom صالحان وA/V offset مُقاس |
| 1000 cuts، فيديو ساعة | قياس RAM والسرعة وUI responsiveness وcancel latency |
| Preview ثم تبديل Original/Processed | مشغل مسموع واحد؛ mapping زمني مقصود |
| Preview ثم تغيير global processing state | export يظل مرتبطًا بالملف المعاين |
| Android release، storage denied/full | فشل واضح أو مكان حفظ صحيح بلا ادعاء gallery success |

معايير قياس native المقترحة وليست نتائج محققة: حدد أولًا tolerance ≤إطار فيديو واحد في precise mode، وقس A/V offset عند البداية/الوسط/النهاية وعبر cuts كثيرة؛ لا تكتفِ بالمقارنة بين مدد الحاوية. استخدم flash/beep أو markers معروفة مع صوت عربي حقيقي لاختبار نهاية الحروف والهمس والتنفس.

## ما يجب إرجاعه للمراجع بعد كل دفعة

- قائمة SR التي تغيرت والسبب الجذري وإصلاحه، مع paths والسطور الحالية.
- وصف ما بقي مفتوحًا ولماذا؛ المخاطر غير المقاسة لا توصف بأنها اختفت.
- أوامر التحقق ونتائجها الفعلية، والمنصة/نوع الوسائط عند الاختبار الأصلي.
- test فشل قبل الإصلاح ونجح بعده لكل عيب منطقي أساسي؛ لا اختبارات mirror للأوامر وحدها.
- مثال قبل/بعد لفترات الحذف وحساب المدة، مع الحفاظ على source files.
- تحديث PROJECT_MEMORY بعد التنفيذ بحالة «منفذ — بانتظار المراجعة»، ثم تحديثها بعد المراجعة المستقلة بالحالة المتحققة وحدودها، دون محو التاريخ أو إعادة توليد baseline قديمة.

أوامر البداية:

```powershell
flutter analyze --no-pub
flutter test --no-pub
flutter test --no-pub docs/reviews/repro/silence_characterization_test.dart --reporter expanded
```

الاختبار الأخير **يثبت عيوب baseline** بتوقعاتها الحالية؛ بعد الإصلاح يجب تعديل المقابل إلى regression صحيح. عدد اختبارات المشروع الأساسي وقت المراجعة81، وأمثلة المراجعة7.

لم تُرسل هذه التعليمات إلى جلسة OpenCode خارجية، ولم تُطبّق إصلاحات التطبيق في جولة المراجعة؛ هذا ملف تسليم قابل للمراجعة داخل المشروع.
