import 'package:lichess_mobile/src/model/analysis/ai_coach_answer.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_validation.dart';
import 'package:lichess_mobile/src/model/engine/practice_comment.dart';
import 'package:material_ui/material_ui.dart';

Color _verdictColor(MoveVerdict verdict) => switch (verdict) {
  MoveVerdict.goodMove => const Color(0xFF2E7D32),
  MoveVerdict.notBest => const Color(0xFF00796B),
  MoveVerdict.inaccuracy => const Color(0xFFF9A825),
  MoveVerdict.mistake => const Color(0xFFEF6C00),
  MoveVerdict.blunder => const Color(0xFFC62828),
};

/// Shows an answer from the coach. A structured answer is laid out as a verdict badge (when the
/// explanation has one), a headline, a card per section with the moves named in it highlighted,
/// and a note on whether the moves were checked. Plain text, such as answers saved before this
/// layout existed and follow-up answers, is shown as it is.
class const AiCoachAnswerView({
  required final String stored,

  /// The verdict the app computed for the move being explained, for the badge.
  final MoveVerdict? verdict,
  super.key,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final answer = AiCoachAnswer.tryParse(stored);
    if (answer == null) return SelectableText(stored);

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget moves(String text, {TextStyle? style}) {
      final base = style ?? theme.textTheme.bodyMedium;
      return SelectableText.rich(
        TextSpan(
          style: base,
          children: [
            for (final piece in splitAiCoachMoves(text))
              TextSpan(
                text: piece.text,
                style: piece.isMove
                    ? TextStyle(
                        fontWeight: FontWeight.w600,
                        backgroundColor: scheme.primaryContainer,
                        color: scheme.onPrimaryContainer,
                      )
                    : null,
              ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (verdict case final verdict?)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Chip(
              label: Text(
                aiCoachVerdictLabel(verdict),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
              backgroundColor: _verdictColor(verdict),
              visualDensity: VisualDensity.compact,
            ),
          ),
        if (answer.headline.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: moves(
              answer.headline,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
        for (final section in answer.sections)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (section.title.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        section.title.toUpperCase(),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  moves(section.text),
                ],
              ),
            ),
          ),
        if (answer.check == AiCoachCheckResult.verified)
          Row(
            children: [
              const Icon(Icons.check_circle_outline, size: 16, color: Color(0xFF2E7D32)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  "Moves checked against Stockfish's lines",
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        if (answer.check == AiCoachCheckResult.unverified)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.warning_amber_rounded, size: 16, color: Color(0xFFEF6C00)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  "Could not verify these moves against Stockfish's lines: "
                  '${answer.unverified.join(', ')}. Treat them with care.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
      ],
    );
  }
}
