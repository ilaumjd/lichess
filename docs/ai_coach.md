# Beginner AI coach (fork feature)

This optional feature is specific to `ilaumjd/lichess`. It is not an official Lichess service.

## Use

1. Open **Settings → AI coach**.
2. Enter your own OpenAI API key and a Chat Completions-compatible model name.
   The default is `gpt-4o-mini`. API billing is separate from a ChatGPT subscription.
3. Open a standard-chess position in Analysis and enable engine analysis.
4. Wait for evaluation depth 12 or greater.
5. Open the app bar **… → Explain position (AI)**.
6. Inspect the evidence, then tap **Explain** to send the request (or reopen an exact saved match).
7. Open **Explanation history** from the explanation screen or AI coach settings to revisit notes.

## What the coach is given

The app computes facts itself (`ai_coach_facts.dart`) and passes them with Stockfish's lines,
so the AI explains them instead of guessing: material balance, check/mate/stalemate, pieces
that are attacked and undefended or attacked by a cheaper piece (pins are ignored), captures
and checks available to the side to move, castling and king state, and the opening name.

When a move is displayed and the engine has analysed both the position before it and after it
(depth 12 or more), the menu says **Explain this move (AI)** and the request contains the move
played, a verdict (good move, not best, inaccuracy, mistake, blunder; same thresholds as the
app's practice mode), the engine's first choice, lines before and after, and facts for both
positions. Otherwise it explains the position (**Explain position (AI)**).

The prompt asks for a fixed structure: Verdict, Why, Idea, Lesson, at most 170 words, in plain
language for a beginner. Stockfish supplies the analysis; an LLM explains it and may be mistaken.

## Answer checking

Moves named in an answer (piece moves, castling, pawn captures, promotions; plain pawn pushes
are not checked because they look like squares) are compared with the moves the app supplied.
On a mismatch the app retries once, telling the model which moves are allowed. If it still
fails, the answer is shown with a visible warning; if it passes and names moves, it carries
"Moves checked against Stockfish's lines". This catches illegal or invented moves. It does not
prove the *reasoning* is right.

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
- Successful answers are saved in device-local app preferences, newest first, with the date,
  model and full position/engine evidence. The newest 100 entries are retained; older ones expire.
  Saving the same evidence and model replaces that entry instead of duplicating it.
- History survives app restarts and can be browsed offline without an API key. An exact saved
  evidence/model match is reused before any API request. Different engine evidence or a different
  model can create a new request. There is no cross-device sync; OS app backups may include notes.
- Explanations are ordinary app data, not encrypted secret storage. The API key is never included.
  Individual entries or all history can be deleted after confirmation. Removing the API key does
  not delete study history. Clearing app data or uninstalling may remove history.
- There is also a 30-entry memory cache. Saving/removing API settings and deleting history clear
  the memory cache. Only successful responses are saved; storage failures leave the answer visible
  with a warning. History writes are serialized to avoid losing simultaneous updates.
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
  test/model/analysis/ai_coach_history_test.dart \
  lib/src/model/analysis/ai_coach_history.dart \
  lib/src/view/analysis/ai_coach_history_screen.dart \
  test/view/analysis/ai_coach_screen_test.dart
flutter test test/model/analysis/ai_coach_test.dart \
  test/model/analysis/ai_coach_history_test.dart \
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
