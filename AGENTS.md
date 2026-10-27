# Project context for Codex, OpenCode, and other coding agents

Read `PROJECT_MEMORY.md` before planning or editing this project. Read
`docs/SOURCE_INVENTORY.md` to locate feature files. For silence removal work,
also read `docs/reviews/SILENCE_REMOVAL_REVIEW_AR.md` and
`docs/reviews/OPENCODE_HANDOFF_AR.md`.

User-required review protocol (2026-10-05): before EVERY review, including
follow-up reviews of OpenCode changes, re-read `PROJECT_MEMORY.md` from disk;
do not rely on a previous turn's copy or conversational memory. After EVERY
review, update that file even if no production code changed: record the date,
reviewer, scope, findings/status, checks actually run, limitations, and next
step. Keep factual project sections consistent with the reviewed source.
Tell the user which memory sections were updated. This protocol applies to
Codex, OpenCode, and any other agent working on this project.

OpenCode implements a bounded batch and records its changes/checks in the
memory as `Implemented — awaiting review`. Codex independently reviews the
actual source and evidence before recording `Verified` (with its validation
scope). Do not erase open issues or report native validation that was not run.

The source code is authoritative. `PROJECT_MAP.md` is historical and contains
claims that no longer match the implementation; do not treat its old fixes,
test counts, or FFmpeg incidents as present-day facts.

The review dated 2026-10-05 is a baseline, not a list of completed fixes.
Preserve the user's current changes. This workspace had no `.git` directory
at review time, so do not claim a clean Git diff or invent a commit baseline.

After meaningful changes, update the relevant memory sections and review
status with actual validation results. Keep existing issue IDs stable.
Never call an issue fixed based only on command-string tests when native
media behavior is involved. Tests under `docs/reviews/repro/` deliberately
characterize existing bugs; convert their expectations into correctness
regressions when fixing those bugs.

Use seconds for domain timelines and explicitly convert to milliseconds for
Dart Duration / FFmpeg statistics. Keep removal intervals finite, sorted,
clamped, nonempty, and non-overlapping before computing their complement.
Do not change a user's source media in place. Own and clean up temporary
files by processing job. Do not edit generated `build/` or `.dart_tool/` files
as application source.

Normal verification: `flutter analyze --no-pub`, `flutter test --no-pub`.
Native FFmpeg/playback/export checks additionally require a supported device.
Communicate review findings and user-facing explanations in Arabic unless
the user asks otherwise; keep identifiers and code in their existing style.
