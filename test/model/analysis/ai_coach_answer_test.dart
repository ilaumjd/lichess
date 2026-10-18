import 'dart:convert';

import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_answer.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_validation.dart';
import 'package:lichess_mobile/src/model/engine/practice_comment.dart';
import 'package:lichess_mobile/src/view/settings/ai_coach_settings_screen.dart';

String reply({String headline = 'A solid move.', List<Map<String, String>>? sections}) =>
    jsonEncode({
      'headline': headline,
      'sections':
          sections ??
          [
            {'title': 'Why', 'text': 'It controls the centre.'},
            {'title': 'Lesson', 'text': 'Develop first.'},
          ],
    });

void main() {
  test('the default model is gpt-6-luna', () {
    expect(aiCoachDefaultModel, 'gpt-6-luna');
  });

  group('AiCoachAnswer.tryParse', () {
    test('reads a headline and sections', () {
      final answer = AiCoachAnswer.tryParse(reply())!;
      expect(answer.headline, 'A solid move.');
      expect(answer.sections.map((s) => s.title), ['Why', 'Lesson']);
      expect(answer.sections.first.text, 'It controls the centre.');
      expect(answer.check, isNull);
    });

    test('reads a reply that a model wrapped in a code fence', () {
      expect(AiCoachAnswer.tryParse('```json\n${reply()}\n```'), isNotNull);
      expect(AiCoachAnswer.tryParse('```\n${reply()}\n```'), isNotNull);
    });

    test('plain text, damaged JSON and other JSON are not answers', () {
      for (final text in [
        '',
        'Play Nf3 to develop a knight.',
        '{"headline": ',
        '[1, 2]',
        '{"other": 1}',
        '{"headline": "", "sections": []}',
        '{"headline": "", "sections": [{"title": "Why", "text": "   "}]}',
        '"just a string"',
      ]) {
        expect(AiCoachAnswer.tryParse(text), isNull, reason: text);
      }
    });

    test('a headline alone, or sections alone, is enough', () {
      expect(AiCoachAnswer.tryParse('{"headline": "Fine.", "sections": []}'), isNotNull);
      expect(
        AiCoachAnswer.tryParse('{"headline": "", "sections": [{"title": "", "text": "Fine."}]}'),
        isNotNull,
      );
    });

    test('skips damaged sections and keeps the good ones', () {
      final answer = AiCoachAnswer.tryParse(
        '{"headline": "x", "sections": [1, {"title": "A"}, {"title": "B", "text": "kept"}, "no"]}',
      )!;
      expect(answer.sections.map((s) => s.title), ['B']);
    });

    test('keeps at most six sections and clips very long text', () {
      final many = reply(
        sections: [
          for (var i = 0; i < 12; i++) {'title': 'T$i', 'text': 'text $i'},
        ],
      );
      expect(AiCoachAnswer.tryParse(many)!.sections, hasLength(kAiCoachMaxSections));
      final long = reply(
        headline: 'h' * 5000,
        sections: [
          {'title': 't' * 200, 'text': 'x' * 5000},
        ],
      );
      final answer = AiCoachAnswer.tryParse(long)!;
      expect(answer.headline.length, lessThanOrEqualTo(1500));
      expect(answer.sections.single.title.length, lessThanOrEqualTo(40));
      expect(answer.sections.single.text.length, lessThanOrEqualTo(1500));
    });
  });

  group('storing', () {
    test('an answer with its check survives being saved and read back', () {
      final answer = AiCoachAnswer.tryParse(reply())!
          .withCheck(AiCoachCheckResult.unverified, unverified: ['Qh5', 'Ke4']);
      final back = AiCoachAnswer.tryParse(answer.toStored())!;
      expect(back.headline, answer.headline);
      expect(back.sections.map((s) => s.text), answer.sections.map((s) => s.text));
      expect(back.check, AiCoachCheckResult.unverified);
      expect(back.unverified, ['Qh5', 'Ke4']);
    });

    test('a verified answer and one with no check', () {
      expect(
        AiCoachAnswer.tryParse(
          AiCoachAnswer.tryParse(reply())!.withCheck(AiCoachCheckResult.verified).toStored(),
        )!.check,
        AiCoachCheckResult.verified,
      );
      expect(AiCoachAnswer.tryParse(AiCoachAnswer.tryParse(reply())!.toStored())!.check, isNull);
    });

    test('an unknown check name is ignored', () {
      final stored = jsonEncode({'headline': 'x', 'sections': <String>[], 'check': 'maybe'});
      expect(AiCoachAnswer.tryParse(stored)!.check, isNull);
    });
  });

  group('plain text', () {
    test('a structured answer is flattened without its check', () {
      final answer = AiCoachAnswer.tryParse(reply())!.withCheck(AiCoachCheckResult.verified);
      expect(
        aiCoachPlainText(answer.toStored()),
        'A solid move.\nWhy: It controls the centre.\nLesson: Develop first.',
      );
    });

    test('an older plain answer loses only the note the app added', () {
      expect(
        aiCoachPlainText("Play Nf3.\n\n✓ Moves checked against Stockfish's lines."),
        'Play Nf3.',
      );
      expect(aiCoachPlainText('Just text.'), 'Just text.');
    });
  });

  group('the schema', () {
    test('asks for a headline and sections, and nothing else', () {
      expect(aiCoachAnswerSchema['required'], ['headline', 'sections']);
      expect(aiCoachAnswerSchema['additionalProperties'], false);
      final sections =
          (aiCoachAnswerSchema['properties']! as Map<String, Object?>)['sections']!
              as Map<String, Object?>;
      final item = sections['items']! as Map<String, Object?>;
      expect(item['required'], ['title', 'text']);
      expect(item['additionalProperties'], false);
    });
  });

  group('verdict from evidence', () {
    String evidence(String verdict) =>
        'Task: x\nVerdict (computed by the app from the change in evaluation): $verdict\nMore.';

    test('every verdict the evidence can state is recognised', () {
      expect(aiCoachVerdictFromEvidence(evidence('good move')), MoveVerdict.goodMove);
      expect(
        aiCoachVerdictFromEvidence(evidence('not the best move, but the position stays winning')),
        MoveVerdict.notBest,
      );
      expect(
        aiCoachVerdictFromEvidence(evidence('inaccuracy (a small slip)')),
        MoveVerdict.inaccuracy,
      );
      expect(aiCoachVerdictFromEvidence(evidence('mistake')), MoveVerdict.mistake);
      expect(
        aiCoachVerdictFromEvidence(evidence('blunder (a serious error)')),
        MoveVerdict.blunder,
      );
    });

    test('other evidence, or a verdict it does not know, gives none', () {
      expect(aiCoachVerdictFromEvidence('Task: explain this position.'), isNull);
      expect(aiCoachVerdictFromEvidence(evidence('something else')), isNull);
      // The "why not" evidence has its own verdict line and must not be mistaken for this one.
      expect(
        aiCoachVerdictFromEvidence(
          'Verdict for Nf3 (computed by the app from the change in evaluation): blunder (a serious error)',
        ),
        isNull,
      );
    });

    test('every verdict has a label', () {
      expect(
        MoveVerdict.values.map(aiCoachVerdictLabel).toSet(),
        hasLength(MoveVerdict.values.length),
      );
    });
  });

  group('splitAiCoachMoves', () {
    test('cuts text into moves and ordinary text, and joins back to the original', () {
      const text = 'Play Nf3, then Bb5+ and O-O. The pawn on e4 stays.';
      final pieces = splitAiCoachMoves(text);
      expect(pieces.map((p) => p.text).join(), text);
      expect(pieces.where((p) => p.isMove).map((p) => p.text), ['Nf3', 'Bb5+', 'O-O']);
    });

    test('text with no moves is one ordinary piece, and empty text is nothing', () {
      expect(splitAiCoachMoves('No moves here.').single.isMove, isFalse);
      expect(splitAiCoachMoves(''), isEmpty);
    });

    test('text that is only a move', () {
      final pieces = splitAiCoachMoves('Nf3');
      expect(pieces.single.isMove, isTrue);
    });
  });

  test('a stored list of unverified moves is never shared between answers', () {
    final a = AiCoachAnswer.tryParse(reply())!
        .withCheck(AiCoachCheckResult.unverified, unverified: ['Qh5']);
    final b = a.withCheck(AiCoachCheckResult.verified);
    expect(b.unverified, const IListConst<String>([]));
    expect(a.unverified, ['Qh5']);
  });
}
