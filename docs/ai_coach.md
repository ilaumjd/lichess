# Beginner AI coach (fork feature)

This optional feature is specific to `ilaumjd/lichess`. It is not an official Lichess service.

## Use

1. Open **Settings → AI coach**.
2. Enter your own OpenAI API key and a Chat Completions-compatible model name.
   The default is `gpt-4o-mini`. API billing is separate from a ChatGPT subscription.
3. Open a standard-chess position in Analysis and enable engine analysis.
4. Wait for evaluation depth 12 or greater.
5. Open the app bar **… → Explain position (AI)**.
6. Inspect the evidence, then tap **Explain** to send the request.

The beginner prompt asks for an assessment, the purpose of an engine candidate,
the opponent's reply in that line, and one simple lesson in everyday language.
Stockfish supplies the analysis; an LLM explains it and may be mistaken.

## Boundaries

- No automatic requests, move execution, or online-game assistance.
- The analysis screen's existing `isComputerAnalysisAllowed` permission gates the action.
- Standard chess only. Threat mode must be disabled.
- Exact FEN matching prevents using engine evidence for a different position.
- Up to three principal variations and twelve half-moves per variation are sent.
  Each included move is checked for legality and converted to SAN.
- Scores are labelled as White-relative, matching Lichess's evaluation model.
- Move history includes only moves leading to the displayed position, without future moves,
  player names, account credentials, PGN comments, or other game headers.
- The API key and model are saved with the app's existing OS-backed secure storage.
  This does not protect against a compromised/rooted device.
- Requests go directly to `https://api.openai.com/v1/chat/completions` over HTTPS,
  using a separate HTTP client without Lichess authentication or request logging.
  OpenAI receives the position, engine lines, moves and the connection's IP address.
  Its API data policies apply; this is not offline/private engine analysis.
- Successful answers are cached in memory (30 entries) by model and exact evidence.
  Saving/removing settings clears the cache. Restarting the app loses the cache.
- Errors do not display raw provider responses. There is no automatic retry or paid key test.

## Validation

Use the Flutter SDK version required by `pubspec.yaml`:

```sh
flutter pub get
dart run build_runner build
flutter analyze lib/src/model/analysis/ai_coach.dart \
  lib/src/model/analysis/analysis_controller.dart \
  lib/src/view/analysis/ai_coach_screen.dart \
  lib/src/view/analysis/analysis_screen.dart \
  lib/src/view/settings/ai_coach_settings_screen.dart \
  lib/src/view/settings/settings_screen.dart \
  test/model/analysis/ai_coach_test.dart \
  test/view/analysis/ai_coach_screen_test.dart
flutter test test/model/analysis/ai_coach_test.dart \
  test/view/analysis/ai_coach_screen_test.dart \
  test/view/analysis/analysis_screen_test.dart
```

A real Android build/device test and an actual API response still need verification.
Do not publish this fork as the official Lichess app. Retain GPLv3 notices and provide
corresponding source when distributing it, and review branding/build configuration first.

## AI assistance disclosure

Implementation and tests were generated with OpenAI GPT-6.1-sol through the pi coding agent.
Human review is required before upstream contribution or release, following `AI_POLICY.md`.
No upstream PR has been opened.
