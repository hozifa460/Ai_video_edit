# المراجعة العامة للمشروع — 2026-10-05

المراجعة تشمل حصر البنية والخصائص ومسارات البيانات والخدمات المشتركة والاختبارات والإعدادات الأصلية. التدقيق التفصيلي الأول مخصص لإزالة السكتات في `SILENCE_REMOVAL_REVIEW_AR.md`. هذا الملف يسجل نتائج عابرة للأقسام وأولويات المراجعات التالية؛ لا يمثل اعتمادًا وظيفيًا لكل شاشة أو لكل جهاز.

## ما هو موجود بالفعل

المنتج أوسع من Silence Remover: استيراد محلي/URL/YouTube، Media Cutter بأوضاع قص وحذف متعدد وتقسيم، Audio Editor، Audio Enhancer، Video Adjuster، Video Enhancer، Shorts مع reframing ومسودات. يوجد تنظيم feature-first وكيانات ومستودعات وواجهات Riverpod، لكن الفصل لا يُطبق بالتساوي. تفاصيل المزايا والمسارات والاعتمادات في `PROJECT_MEMORY.md` وفهرس كامل للملفات في `docs/SOURCE_INVENTORY.md`.

جوانب مفيدة موجودة: command builders قابلة للاختبار في cutter/audio/enhancement؛ اختبارات81 ناجحة؛ static analyzer نظيف؛ raw waveform يُنظف في finally؛ مسار معالجة السكتات يبدأ ProcessingState جديدة لإزالة output القديم من المحاولة السابقة؛ cutter الأحدث لديه session cancellation وrange validation. ينبغي الحفاظ على هذه التحسينات بدل إعادة كتابة عمياء.

## نتائج عامة تحتاج معالجة

### G-01 — P1 — اسم ملف التنزيل من الخادم قد يتجاوز مجلد التنزيل

الموضع: `lib/core/services/video_download_service.dart:508` و`:112`–`:121`.

`_extractFilename` يأخذ Content-Disposition بعد أول `=`، يزيل quotes، ثم يعيده بلا basename أو تحقق containment. `downloadVideo` يربطه بمجلد documents ويحذف الملف الموجود قبل الكتابة. قيمة مثل `filename="../existing.mp4"` قد تصل إلى ملف آخر ضمن صلاحيات التطبيق. هذه ثغرة مسار مثبتة بتتبع الكود؛ لم يُنفذ تنزيل خبيث أو حذف ملف في المراجعة.

الإصلاح: parser صحيح للهيدر، اسم مولد فريد، reject path separators/absolute paths/dot segments، تحقق أن المسار النهائي داخل دليل تنزيل مخصص، كتابة ملف جديد ثم rename بعد validation. القبول: malicious header وduplicate names وUnicode واسم فارغ لا تستبدل أي ملف خارج download job.

### G-02 — P1 — إذن الإنترنت غائب عن manifest الأساسي

الموضع: `android/app/src/main/AndroidManifest.xml`، مقارنة بـ`src/debug/AndroidManifest.xml` و`src/profile/AndroidManifest.xml`.

INTERNET مصرح به في debug/profile فقط؛ ميزة الرابط/YouTube قد تعمل أثناء التطوير وتفشل في release ما لم توفره مكتبة أخرى بالدمج. يلزم التصريح في main وفحص merged **release** manifest، ثم تجربة تنزيل في build release على جهاز. لم يُبنَ release في هذه الجولة.

### G-03 — P2 — حساب معدل الإطارات الكسري خاطئ

الموضع: `lib/features/video_import/data/repositories/video_import_repository_impl.dart` عند `fpsParts`.

يعالج `30000/1001` بأخذ30000 فقط. metadata والواجهة ستعرض FPS غير صحيح، وقد تنتقل القيمة لأي consumer لاحق. الإصلاح: قسمة البسط على المقام مع حالات0/0 وNaN/Infinity؛ اختبار30000/1001 و24000/1001 و30 وunknown.

### G-04 — P2 — استعادة مسودة Shorts تفقد خيارات التصدير

الموضع: `lib/core/services/draft_service.dart` في `saveFullProject` و`DraftData.restoreProject`.

quality تُكتب إلى JSON ولا تُقرأ عند restore؛ fps لا يُحفظ ولا يُستعاد. provider setters في `shorts_provider.dart` تعيد بناء ExportSettings دون تمرير fps أيضًا. استعادة مشروع ultra يمكن أن تعود إلى default high. الإصلاح: serialization موحد versioned + copyWith، واختبار round-trip لكل خاصية لا path فقط.

### G-05 — P2 — إعدادات Custom في Shorts ليست مخصصة فعليًا

الموضع: `shorts_generator/domain/entities/export_settings.dart` getters.

`ClipDuration.custom` يعيد60s، وPlatformTarget.custom يعيد1080×1920؛ الكيان لا يحمل custom dimensions/duration. إذا بقي الاختيار ظاهرًا فهو لا يمثل إعدادًا مستقلًا. الإصلاح: حقول مخصصة validatable مع UI، أو إخفاء الخيارات غير المنفذة؛ اختبار سلوك المستخدم لا enum فقط.

### G-06 — P2 — تحريك crop فقط لا يدخل في hasAdjustment

الموضع: `video_adjustment/domain/entities/video_adjustment.dart` getter `hasAdjustment`.

cropX/cropY حقول موجودة لكنها ليست في شرط hasAdjustment، بينما cropWidth/cropHeight موجودان. تغييرات offsets وحدها قد لا تمر من شروط بناء/تطبيق التعديلات. يلزم تتبع recipe/filter pipeline كاملًا وإضافة اختبار offset-only قبل اعتبار الإصلاح مكتملًا.

### G-07 — P2 — فتح ملف جديد في Enhancer يحتفظ بنتائج الملف السابق

الموضع: `video_enhancement/presentation/providers/enhancement_provider.dart` في `setVideoPath` وcopyWith.

setVideoPath يغير path/screen فقط، ويحتفظ analysis/plan/previewFrames/result. الشاشة تطلب analysis لاحقًا، لكن يوجد خطر نتائج طلب قديم تصل بعد تبديل الملف وتلوّث حالة الملف الجديد. العلاج مماثل session/generation scoped في السكتات؛ اختبار فتحB أثناء تحليلA ورفض completion القديم.

### G-08 — P2 — تجهيز release ما زال تجريبيًا

الموضع: `android/app/build.gradle.kts`.

applicationId تجريبي وrelease يستخدم debug signing. هذه إعدادات فعلية غير جاهزة لنشر إنتاجي؛ لا يلزم تغييرها في جولة مراجعة السكتات. ينبغي أن يحدد المستخدم هوية التطبيق ومسار التوقيع عند طلب النشر، دون كتابة أسرار في الذاكرة أو المستودع.

### G-09 — P2 — التوثيق التاريخي قد يقود النموذج إلى تغييرات خاطئة

الموضع: `PROJECT_MAP.md`.

يذكر subtitle_generation وvosk غير الموجودين، حماية50ms غير الموجودة، أرقام اختبارات قديمة وتحذيرات19 لا يعيدها analyzer الحالي. يحتفظ السجل بقيمته التاريخية لكنه لا يصلح كعقد تنفيذ. أضيف `AGENTS.md` و`PROJECT_MEMORY.md` وتنبيه أعلى السجل لتوجيه النماذج إلى الوضع الحالي.

## مسائل تتطلب تدقيقًا لاحقًا

- مراجعة تنزيلات HTTP/YouTube كاملة: حدود الحجم/الوقت، server filenames، حفظ الملفات الموجودة، cancellation أثناء غياب وصول bytes، وإخفاء query tokens من logs عند وجود روابط موقعة. لا يلزم إرسال روابط المستخدم إلى جهة أخرى.
- الفرق بين preview frame والتصدير الفعلي في Video Adjuster/Enhancer؛ جميع settings يجب أن تعطي recipe موحدًا. الprovider الحالي للتحسين يستخدم `enhanceVideoDirect`؛ repository stream الأقدم فيه مدة60000 ثابتة لكنه ليس المسار الرئيسي الحالي، فلا تُنسب المشكلة للشاشة قبل تتبع الاستدعاء.
- في cutter متعدد الأجزاء، `_run` يعيد `_cancelled=false` لكل أمر؛ اختبر cancel بين الأجزاء وفي window إنشاء session. quote لأسماء concat list يحتاج تدقيق apostrophe escaping على المنصات التي تسمح به.
- تكرار أسماء classes مثل PreviewScreen/ProcessingScreen/ExportQuality بين features يزيد خطر import خاطئ؛ استخدم imports محددة/aliases.
- cleanup وglobal FFmpeg callbacks في جميع الميزات، لا خدمة واحدة فقط؛ وبناء حالات copyWith يمكنها مسح nullable error/output صراحة.
- تحقق جهاز فعلي من Android scoped storage وgallery visibility، وiOS plugin deployment requirements/permissions. لا تجعل وجود فولدر web وعدًا بدعم web.
- الاختبارات الحالية مركزة على pure commands؛ يلزم اختبار provider races وwaveform/PCM وscreen lifecycle وملفات native A/V قبل الثقة في سلوك الوسائط.

## خطة مراجعة بقية الأقسام

| الترتيب | القسم | معيار اكتمال المراجعة التالية |
|---|---|---|
| 1 | إصلاحات السكتات | عقود timeline + اختبارات regression + native fixtures |
| 2 | الاستيراد/تنزيل الملفات | حصر المسارات، عدم overwrite غير مقصود، release networking |
| 3 | Media Cutter / Audio Editor | frame accuracy/fast mode، عدة ranges، cancellation، codecs |
| 4 | Shorts / drafts / faces | round-trip، scoring claims، stream consistency، output framing |
| 5 | Video Adjuster / Enhancer / Audio Enhancer | تطابق preview/export، حدود filters، صحة metadata/quality |
| 6 | المنصات وتجهيز الإصدار | build/release/device/storage lifecycle واستهلاك الموارد |

جميع G-01..G-09 هنا **Open**. تمت إضافة التوثيق فقط؛ لا تحمل إضافة هذا الملف معنى أن هذه النتائج أُصلحت.
