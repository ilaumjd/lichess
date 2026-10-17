# AI coach improvement plan

Status: **plan only**. No code, no build. Builds on `docs/ai_coach.md` (current feature).

## Problem

The coach gets a FEN, the move list and Stockfish's top lines, then guesses *why* a move is
good. That produces vague or wrong claims (invented threats, wrong piece names). It also
explains only the current position, never the move the player actually made.

## Principle

**The app computes facts; the AI only explains them.** Every claim in an answer should map to
a fact the app supplied. The AI is never asked to find tactics itself.

## Existing pieces to reuse (verified in the codebase)

- `model/engine/practice_comment.dart`: `MoveVerdict` (good / not best / inaccuracy /
  mistake / blunder) from winning-chance shifts (thresholds 0.05 / 0.11 / 0.24).
- `model/engine/practice_analyser.dart`: evaluates positions before/after a move.
- `service/opening_service.dart` and `assets/chess_openings.db`: opening names.
- `model/explorer/tablebase*.dart`: endgame results.
- `Eval.winningChances` / `winningChancesPovDiff` in `model/common/eval.dart`.
- `dartchess`: legality, SAN, check/mate/stalemate. Piece-attack helpers must be
  re-verified against the pinned `dartchess` version before relying on them.

## Phases

### Phase 1: Grounded facts (highest value)
Add `ai_coach_facts.dart` (pure Dart, no network, unit-testable). For the position, compute:
- material balance (by piece type) and who is ahead;
- side to move, check, checkmate, stalemate;
- hanging / undefended pieces and pieces attacked by lower-value pieces;
- captures and checks available to each side;
- king safety basics (castled or not, pawn shield intact);
- opening name and ECO when in book; tablebase result when 7 pieces or fewer.

Output a compact fact list included in the prompt ("Facts computed by the app, treat as
true"). Keep it short (token cost) and deterministic.

### Phase 2: Explain the move played
- Input: position before, the move played, the engine's best move and eval before/after.
- Compute `MoveVerdict` and the eval shift using the existing thresholds.
- If not best: include the engine's refutation line, and what the best move achieved.
- Prompt shape: "Move played, verdict, best move, why best (facts), what the move allowed."

### Phase 3: Validate AI output
- Extract move mentions (SAN) from the answer; reject or flag any that is illegal in the
  position or absent from the supplied lines.
- On failure: one automatic retry with a stricter reminder, then show a visible
  "could not verify" note instead of silently trusting it.
- Add a footer: "Moves checked against Stockfish lines" only when the check passed.

### Phase 4: Game review
- After a finished game, find the 3 to 5 largest eval swings (verdict mistake or worse) for
  the user's side, plus the opening and result.
- One request per key moment (Phase 2 shape), then a short summary request listing themes
  and one thing to practise. Cache each result in history.
- Cost guard: show an estimate and require a tap before sending more than N requests.

### Phase 5: Levels and teaching style
- Setting: beginner / club / advanced (changes vocabulary, depth, length limits).
- Optional "quiz first" mode: ask "what does White threaten?" and reveal after the user taps.

### Phase 6: Follow-up questions
- Chat-style follow-ups ("why not Nf3?", "simpler please"), with the position, facts and
  previous answer kept as context. Each follow-up re-validates mentioned moves (Phase 3).
  Cap the number of turns to bound cost.

### Phase 7: Patterns over time (optional)
- From saved history, tag recurring mistake themes (hanging pieces, missed forks) and show a
  short "you often..." summary. Local only.

## Entry points (separate from quality work)
Start the engine on demand instead of requiring the analysis screen: game-over screen,
review mode, pasted FEN/PGN, puzzles. Remains disabled where Lichess disallows engine help
(live games). Needs its own small design: engine start, depth wait, cancel, battery use.

## Prompt design changes
- Split the prompt into: role and level, **facts block**, **engine block**, **task block**.
- Ask for a fixed structure (verdict, reason, better idea, lesson) in plain text.
- Forbid claims not supported by the facts or lines; allow "not enough evidence".
- Keep the PGN-as-untrusted-data rule.
- Output length by level; request cap raised only where needed (game review summary).

## Data and privacy
- Same as today: sent only on user tap, directly to OpenAI, key in secure storage,
  history saved locally. Adding facts adds no new personal data.
- History entries gain: level, task type (position / move / game review), validation result.
  Add a stored-format version so old entries still load.

## Testing (no build needed until implementation)
- Facts: table-driven unit tests from FENs (hanging piece, fork, back-rank, stalemate).
- Verdicts: tests with synthetic evals at the threshold boundaries.
- Validation: tests with fake answers containing illegal/unlisted moves.
- Prompt builder: snapshot tests so wording changes are intentional.
- Fake HTTP client for request/retry/cost-guard behavior.
- Manual: a short set of reference positions to compare answers before and after.

## Risks and open questions
- **Cost:** more context and review mode raise token use. Mitigate with caching, estimates
  and a per-review request cap.
- **Latency:** game review needs multiple engine runs and requests; show progress, allow cancel.
- **Fact accuracy:** hanging-piece and pin detection must be right; wrong facts are worse
  than none. Start with the few reliable ones.
- **Model choice:** a stronger model may explain better but costs more; keep it configurable
  and test two models on the reference set.
- **Engine strength on phone:** deeper analysis drains battery; keep depth bounded.
- Open: main use case (single move vs full review), whether follow-ups matter, acceptable
  cost per explanation, and which entry point to build first.

## Suggested order
1. Phase 1 facts, Phase 2 move explanation, Phase 3 validation (quality core).
2. Entry points (on-demand engine) so the coach is reachable without Analysis.
3. Phase 4 game review.
4. Phases 5 to 7 as wanted.

## AI assistance disclosure
Plan written with OpenAI/Anthropic models via the pi coding agent. Human review required
before implementation or any upstream contribution (see `AI_POLICY.md`).
