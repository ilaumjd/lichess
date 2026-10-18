import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_level.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_move.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/engine/engine_budget.dart';
import 'package:lichess_mobile/src/model/engine/evaluation_context.dart';
import 'package:lichess_mobile/src/model/engine/position_evaluator.dart';
import 'package:lichess_mobile/src/model/engine/practice_analyser.dart';
import 'package:lichess_mobile/src/model/engine/work.dart';

/// How long the coach lets the engine search one position. Depth [kAiCoachMinDepth] is usually
/// reached well before this; the cap is for slow devices, so nobody waits for long.
const kAiCoachSearchTime = Duration(seconds: 4);

/// How long the coach lets the engine look for a threat. Threats are a bonus: when the engine has
/// nothing by then, the coach goes without.
const kAiCoachThreatTime = Duration(seconds: 3);

/// Runs Stockfish on demand, for the coach only, and lets the engine go when it is done.
///
/// Built on the same analyser the practice mode uses, so it also asks the server for a cloud
/// evaluation (instant in the opening) and for a tablebase result in an endgame. Analysis stays
/// on the device: nothing is sent to OpenAI by this class.
final aiCoachEngineProvider = Provider.autoDispose<AiCoachEngine>((ref) {
  final engine = AiCoachEngine(ref);
  ref.onDispose(engine.dispose);
  return engine;
});

class AiCoachEngine(final Ref ref) {
  EvaluationContext? _context;
  ProviderSubscription<EngineEvaluationState>? _subscription;

  late final PracticeAnalyser _analyser = PracticeAnalyser(
    ref: ref,
    evaluator: () => ref.read(positionEvaluatorProvider(_context!).notifier),
    alwaysRequestCloudEvals: true,
    onEval: (_, _) {},
  );

  /// The deepest evaluation known for [position], however shallow, or null.
  ClientEval? known(Position position) => _analyser.evalFor(position);

  /// Evaluates [position] to at least the depth [level] needs, waiting up to [timeout] (by default
  /// the time [level] allows).
  ///
  /// Returns whatever was reached when the time ran out, which may be shallower than the
  /// threshold (or null); callers decide whether that is good enough.
  Future<ClientEval?> evaluate(
    Position position, {
    Duration? timeout,
    AiCoachLevel level = AiCoachLevel.beginner,
  }) async {
    final searchTime = timeout ?? level.searchTime;
    final cached = _analyser.evalFor(position);
    if (cached != null && cached.depth >= level.minDepth) return cached;

    final context = EvaluationContext(
      id: const StringId('ai-coach'),
      variant: Variant.standard,
      initialPosition: position,
    );
    if (_context != context) {
      _subscription?.close();
      _context = context;
      _subscription = ref.listen(
        positionEvaluatorProvider(context),
        _analyser.onEvaluatorStateChanged,
      );
    }

    final budget = ref.read(engineBudgetProvider);
    _analyser.analyse(
      EvalWork(
        id: context.id,
        variant: Variant.standard,
        threads: budget.offlineEvalThreads,
        searchTime: searchTime,
        multiPv: level.multiPv(budget.offlineEvalMultiPv),
        threatMode: false,
        initialPosition: position,
        steps: const IListConst<Step>([]),
      ),
    );
    final eval = await _analyser.usableEval(
      position,
      timeout: searchTime,
      minDepth: level.minDepth,
    );
    // The search would otherwise run on to the practice target depth, using battery for nothing.
    _analyser.yieldEngine();
    return eval;
  }

  /// Evaluates what the side *not* to move threatens in [position] (the engine analyses the same
  /// board as if it were their turn), or returns null if nothing deep enough came in time.
  ///
  /// Searches the evaluator directly rather than through the analyser, because the analyser keys
  /// its results by position and a threat result must not replace the real one.
  Future<ClientEval?> evaluateThreat(
    Position position, {
    Duration timeout = kAiCoachThreatTime,
  }) async {
    if (!canAiCoachShowThreat(position)) return null;
    final context = EvaluationContext(
      id: const StringId('ai-coach-threat'),
      variant: Variant.standard,
      initialPosition: position,
    );
    final subscription = ref.listen(positionEvaluatorProvider(context), (_, _) {});
    final evaluator = ref.read(positionEvaluatorProvider(context).notifier);
    final budget = ref.read(engineBudgetProvider);
    final work = EvalWork(
      id: context.id,
      variant: Variant.standard,
      threads: budget.offlineEvalThreads,
      searchTime: timeout,
      multiPv: 1,
      threatMode: true,
      initialPosition: position,
      steps: const IListConst<Step>([]),
    );

    final done = Completer<ClientEval?>();
    ClientEval? best;
    final results = evaluator
        .evaluate(work)
        .listen(
          (result) {
            best = result.$2;
            if (result.$2.depth >= kAiCoachThreatMinDepth && !done.isCompleted) done.complete(best);
          },
          onDone: () {
            if (!done.isCompleted) done.complete(best);
          },
        );
    final timer = Timer(timeout, () {
      if (!done.isCompleted) done.complete(best);
    });
    try {
      return await done.future;
    } finally {
      timer.cancel();
      // Not awaited: letting go of the stream need not hold up the answer.
      unawaited(results.cancel());
      evaluator.stop();
      subscription.close();
    }
  }

  /// Stops any search and lets the engine go.
  void cancel() => _analyser.yieldEngine();

  void dispose() {
    _analyser.dispose();
    _subscription?.close();
  }
}

/// Whether [eval] can be used as it is for [position].
bool _usable(Position position, ClientEval? eval, AiCoachLevel level) =>
    eval != null &&
    eval.position.fen == position.fen &&
    eval.depth >= level.minDepth &&
    eval.pvs.isNotEmpty;

/// Builds the request for the position or move shown, running the engine only for the positions
/// that have no usable evaluation yet.
///
/// Prefers explaining the move when [move] is given and falls back to the position if the move
/// cannot be explained (for example when the engine ran out of time on the position before it).
Future<AiCoachRequest> prepareAiCoachRequest(
  AiCoachEngine engine, {
  required Position position,
  required ClientEval? currentEval,
  required String moves,
  String? opening,
  AiCoachMoveContext? move,
  AiCoachLevel level = AiCoachLevel.beginner,
}) async {
  Future<ClientEval?> evalFor(Position at, ClientEval? existing) =>
      _usable(at, existing, level) ? Future.value(existing) : engine.evaluate(at, level: level);

  if (move != null && move.before.isLegal(move.played.move)) {
    final after = move.before.playUnchecked(move.played.move);
    // A move that ends the game has no position after it to evaluate.
    final gameOver = after.isGameOver;
    final evalAfter = gameOver ? null : await evalFor(after, move.evalAfter);
    final evalBefore = await evalFor(move.before, move.evalBefore);
    // Only worth a search once the move can be explained at all.
    final canExplain =
        _usable(move.before, evalBefore, level) && (gameOver || _usable(after, evalAfter, level));
    final threatBefore = canExplain ? await engine.evaluateThreat(move.before) : null;
    // An engine that had nothing for the first threat will not have more for the second: skip it
    // rather than make the user wait twice.
    final threatAfter = threatBefore != null && !gameOver
        ? await engine.evaluateThreat(after)
        : null;
    try {
      return makeAiCoachMoveRequest(
        before: move.before,
        played: move.played,
        evalBefore: evalBefore,
        evalAfter: evalAfter,
        movesBefore: move.movesBefore,
        opening: opening,
        threatBefore: threatBefore,
        threatAfter: threatAfter,
        level: level,
      );
    } on AiCoachException {
      // Fall through to the position.
    }
  }
  if (position.isGameOver) {
    throw const AiCoachException(
      'The game is over in this position, so there is nothing for Stockfish to analyse. '
      'Explain the last move instead.',
    );
  }
  final eval = await evalFor(position, currentEval);
  final threat = _usable(position, eval, level) ? await engine.evaluateThreat(position) : null;
  return makeAiCoachRequest(position, eval, moves, opening: opening, threat: threat, level: level);
}
