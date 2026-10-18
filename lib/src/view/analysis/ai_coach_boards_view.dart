import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/settings/board_preferences.dart';
import 'package:material_ui/material_ui.dart';

/// The arrow for the engine's preferred move.
const _bestColor = Color(0xCC15781B);

/// The arrow for the move that was played.
const _playedColor = Color(0xCCCC3333);

/// The biggest a single board gets, so it does not fill a tablet screen.
const _maxBoardSize = 360.0;

/// The size of the small board used in lists.
const _compactBoardSize = 150.0;

/// Draws the position of an explanation. For a move it shows the position before it, with the move
/// played and the engine's preferred move as arrows, and the position after it, next to each other.
/// For a position it shows one board with the engine's preferred move.
class const AiCoachBoardsView({
  required final AiCoachBoards boards,

  /// One small board, without labels or legend: the position before the move with the arrows.
  /// For lists, where several boards share the screen.
  final bool compact = false,

  /// What the red arrow stands for, in the legend.
  final String playedLabel = 'the move played',
  super.key,
}) extends ConsumerWidget {
  Set<Shape> _arrows() {
    final best = boards.best;
    final played = boards.played;
    return {
      if (best is NormalMove) Arrow(color: _bestColor, orig: best.from, dest: best.to),
      // When the move played is the engine's choice, one arrow says it all.
      if (played is NormalMove && played != best)
        Arrow(color: _playedColor, orig: played.from, dest: played.to),
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = StaticChessboardSettings.fromBoardSettings(
      ref.watch(boardPreferencesProvider).toBoardSettings(Variant.standard),
    );
    final before = boards.before;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (compact) {
          return StaticChessboard(
            size: constraints.maxWidth.clamp(0.0, _compactBoardSize),
            fen: (before ?? boards.position).fen,
            orientation: boards.orientation,
            shapes: _arrows(),
            settings: settings,
          );
        }
        const gap = 12.0;
        final hasTwo = before != null;
        final size = hasTwo
            ? ((constraints.maxWidth - gap) / 2).clamp(0.0, _maxBoardSize)
            : constraints.maxWidth.clamp(0.0, _maxBoardSize);

        Widget board({
          required String label,
          required Position position,
          Move? lastMove,
          Set<Shape> shapes = const {},
        }) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StaticChessboard(
                size: size,
                fen: position.fen,
                orientation: boards.orientation,
                lastMove: lastMove,
                shapes: shapes,
                settings: settings,
              ),
              const SizedBox(height: 4),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          );
        }

        final legend = boards.best == null && boards.played == null
            ? null
            : [
                if (boards.best != null) "Green arrow: the engine's preferred move.",
                if (boards.played != null && boards.played != boards.best)
                  'Red arrow: $playedLabel.',
              ].join(' ');

        return Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (before != null) ...[
                  board(label: 'Before the move', position: before, shapes: _arrows()),
                  const SizedBox(width: gap),
                  board(
                    label: 'After the move',
                    position: boards.position,
                    lastMove: boards.played,
                  ),
                ] else
                  board(label: 'The position', position: boards.position, shapes: _arrows()),
              ],
            ),
            if (legend != null && legend.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  legend,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        );
      },
    );
  }
}
