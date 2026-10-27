# AI Video Studio

Flutter application for silence removal, video/audio cutting, audio editing,
video adjustments and enhancement, and Shorts generation.

Project context for developers and coding agents:

- [Persistent project memory (Arabic)](PROJECT_MEMORY.md)
- [Agent entry point](AGENTS.md)
- [Source inventory](docs/SOURCE_INVENTORY.md)
- [General project review](docs/reviews/PROJECT_REVIEW_AR.md)
- [Silence-removal review](docs/reviews/SILENCE_REMOVAL_REVIEW_AR.md)
- [OpenCode handoff and acceptance tests](docs/reviews/OPENCODE_HANDOFF_AR.md)

Review baseline: 2026-10-05, Flutter 3.38.3 / Dart 3.10.1, 81 existing tests
passing and no analyzer issues. Native media/device behavior is not certified
by these unit tests. See the reviews for known issues and validation limits.

## Verification

```powershell
flutter analyze --no-pub
flutter test --no-pub
```

The separate audit examples deliberately reproduce existing bugs:

```powershell
flutter test --no-pub docs/reviews/repro/silence_characterization_test.dart
```

For setup, use the installed Flutter SDK compatible with `pubspec.yaml` and
the package versions in `pubspec.lock`. Android/iOS device validation is
needed for native media processing. Do not infer desktop or web support
from unit tests running on Windows.
