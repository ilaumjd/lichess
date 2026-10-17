import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
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

  /// Evaluates [position] to at least [kAiCoachMinDepth], waiting up to [timeout].
  ///
  /// Returns whatever was reached when the time ran out, which may be shallower than the
  /// threshold (or null); callers decide whether that is good enough.
  Future<ClientEval?> evaluate(Position position, {Duration timeout = kAiCoachSearchTime}) async {
    final cached = _analyser.evalFor(position);
    if (cached != null && cached.depth >= kAiCoachMinDepth) return cached;

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
        searchTime: timeout,
        multiPv: budget.offlineEvalMultiPv,
        threatMode: false,
        initialPosition: position,
        steps: const IListConst<Step>([]),
      ),
    );
    final eval = await _analyser.usableEval(position, timeout: timeout, minDepth: kAiCoachMinDepth);
    // The search would otherwise run on to the practice target depth, using battery for nothing.
    _analyser.yieldEngine();
    return eval;
  }

  /// Stops any search and lets the engine go.
  void cancel() => _analyser.yieldEngine();

  void dispose() {
    _analyser.dispose();
    _subscription?.close();
  }
}

/// Whether [eval] can be used as it is for [position].
bool _usable(Position position, ClientEval? eval) =>
    eval != null &&
    eval.position.fen == position.fen &&
    eval.depth >= kAiCoachMinDepth &&
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
}) async {
  Future<ClientEval?> evalFor(Position at, ClientEval? existing) =>
      _usable(at, existing) ? Future.value(existing) : engine.evaluate(at);

  if (move != null && move.before.isLegal(move.played.move)) {
    final after = move.before.playUnchecked(move.played.move);
    final evalAfter = await evalFor(after, move.evalAfter);
    final evalBefore = await evalFor(move.before, move.evalBefore);
    try {
      return makeAiCoachMoveRequest(
        before: move.before,
        played: move.played,
        evalBefore: evalBefore,
        evalAfter: evalAfter,
        movesBefore: move.movesBefore,
        opening: opening,
      );
    } on AiCoachException {
      // Fall through to the position.
    }
  }
  final eval = await evalFor(position, currentEval);
  return makeAiCoachRequest(position, eval, moves, opening: opening);
}
