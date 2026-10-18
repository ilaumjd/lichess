import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_input.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_review.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';

/// A scan for [plies] from white-side centipawn scores per position, one more than there are
/// plies. The engine's preferred move is always a legal move other than the one played, unless
/// the ply is in [playedIsBest].
AiCoachScan scanFrom(
  IList<AiCoachPly> plies,
  List<int?> cps, {
  Set<int> playedIsBest = const {},
  int depth = 10,
}) {
  final positions = [
    for (final ply in plies) ply.before,
    plies.last.before.playUnchecked(plies.last.move.move),
  ];
  return IList([
    for (var i = 0; i < positions.length; i++)
      if (cps[i] == null)
        null
      else
        () {
          final position = positions[i];
          String best;
          if (i < plies.length && playedIsBest.contains(i)) {
            best = plies[i].move.move.uci;
          } else {
            final played = i < plies.length ? plies[i].move.move.uci : '';
            best = position.legalMoves.entries
                .expand((e) => e.value.squares.map((to) => '${e.key.name}${to.name}'))
                .firstWhere((uci) => uci != played);
          }
          return CloudEval(
            position: position,
            depth: depth,
            nodes: 1,
            pvs: IList([
              PvData(moves: IList([best]), cp: cps[i]),
            ]),
          ) as ClientEval;
        }(),
  ]);
}
