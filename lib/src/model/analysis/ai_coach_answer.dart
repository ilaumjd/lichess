import 'dart:convert';

import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:lichess_mobile/src/model/engine/practice_comment.dart';

/// One titled paragraph of an answer.
typedef AiCoachSection = ({String title, String text});

/// How the app checked the moves an answer names.
enum AiCoachCheckResult() {
  verified,
  unverified,
}

/// The most sections an answer may have, and the longest title and text kept.
const kAiCoachMaxSections = 6;
const _maxTitle = 40;
const _maxText = 1500;

/// The JSON schema the AI is asked to follow, which is what lets the app lay the answer out
/// instead of showing one block of text.
const aiCoachAnswerSchema = <String, Object>{
  'type': 'object',
  'properties': {
    'headline': {'type': 'string', 'description': 'One sentence that sums the answer up.'},
    'sections': {
      'type': 'array',
      'description': 'The titled paragraphs, in the order asked for.',
      'items': {
        'type': 'object',
        'properties': {
          'title': {'type': 'string'},
          'text': {'type': 'string'},
        },
        'required': ['title', 'text'],
        'additionalProperties': false,
      },
    },
  },
  'required': ['headline', 'sections'],
  'additionalProperties': false,
};

/// An answer from the AI, laid out as a headline and titled sections, plus what the app found when
/// it checked the moves the answer names. Stored as JSON, so [AiCoachAnswer.tryParse] also tells
/// answers apart from the plain text saved before this format existed.
class const AiCoachAnswer({
  required final String headline,
  required final IList<AiCoachSection> sections,
  final AiCoachCheckResult? check,
  final IList<String> unverified = const IListConst([]),
}) {
  /// The answer as plain text, without the check, for sending back to the AI as context.
  String get plainText => [
    if (headline.isNotEmpty) headline,
    for (final section in sections) '${section.title}: ${section.text}',
  ].join('\n');

  AiCoachAnswer withCheck(AiCoachCheckResult? check, {Iterable<String> unverified = const []}) =>
      AiCoachAnswer(
        headline: headline,
        sections: sections,
        check: check,
        unverified: unverified.toIList(),
      );

  /// The answer in the form it is saved in.
  String toStored() => jsonEncode({
    'headline': headline,
    'sections': [
      for (final s in sections) {'title': s.title, 'text': s.text},
    ],
    if (check != null) 'check': check!.name,
    if (unverified.isNotEmpty) 'unverified': unverified.toList(),
  });

  /// Reads an answer from [text]: the AI's reply, or a saved answer. Returns null when [text] is
  /// not such an answer (for example plain text), so the caller can show it as it is.
  static AiCoachAnswer? tryParse(String text) {
    var body = text.trim();
    // Some models wrap JSON in a code fence even when told not to.
    final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(body);
    if (fence != null) body = fence.group(1)!;
    if (!body.startsWith('{')) return null;
    try {
      final data = jsonDecode(body);
      if (data is! Map<String, dynamic>) return null;
      final headline = (data['headline'] as String? ?? '').trim();
      final sections = <AiCoachSection>[];
      for (final raw in data['sections'] as List<dynamic>? ?? const []) {
        if (raw is! Map<String, dynamic>) continue;
        final title = (raw['title'] as String? ?? '').trim();
        final sectionText = (raw['text'] as String? ?? '').trim();
        if (sectionText.isEmpty) continue;
        sections.add((title: _clip(title, _maxTitle), text: _clip(sectionText, _maxText)));
        if (sections.length == kAiCoachMaxSections) break;
      }
      if (headline.isEmpty && sections.isEmpty) return null;
      return AiCoachAnswer(
        headline: _clip(headline, _maxText),
        sections: sections.toIList(),
        check: AiCoachCheckResult.values.where((c) => c.name == data['check']).firstOrNull,
        unverified: [
          for (final move in data['unverified'] as List<dynamic>? ?? const [])
            if (move is String) move,
        ].toIList(),
      );
    } on Object {
      return null;
    }
  }
}

String _clip(String text, int max) =>
    text.length <= max ? text : text.substring(0, max).trimRight();

/// A short label for a verdict, for a badge.
String aiCoachVerdictLabel(MoveVerdict verdict) => switch (verdict) {
  MoveVerdict.goodMove => 'Good move',
  MoveVerdict.notBest => 'Not the best',
  MoveVerdict.inaccuracy => 'Inaccuracy',
  MoveVerdict.mistake => 'Mistake',
  MoveVerdict.blunder => 'Blunder',
};

/// The verdict a move explanation's evidence states (computed by the app), or null for any other
/// evidence. Read from the evidence so that saved explanations get their badge too.
MoveVerdict? aiCoachVerdictFromEvidence(String evidence) {
  final line = RegExp(
    r'^Verdict \(computed by the app from the change in evaluation\): (.+)$',
    multiLine: true,
  ).firstMatch(evidence)?.group(1)?.trim();
  if (line == null) return null;
  const texts = {
    'good move': MoveVerdict.goodMove,
    'not the best move, but the position stays winning': MoveVerdict.notBest,
    'inaccuracy (a small slip)': MoveVerdict.inaccuracy,
    'mistake': MoveVerdict.mistake,
    'blunder (a serious error)': MoveVerdict.blunder,
  };
  return texts[line];
}
