import 'dart:convert';

import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/binding.dart';

/// A question asked after an explanation, with its answer.
typedef AiCoachFollowUp = ({String question, String answer});

/// Immutable, device-local study history. No credentials are stored with an explanation.
typedef AiCoachHistoryEntry = ({
  DateTime savedAt,
  String model,
  String evidence,
  String explanation,
  IList<AiCoachFollowUp> followUps,
});

const aiCoachHistoryStorageKey = 'aiCoach.explanationHistory.v1';
const aiCoachHistoryLimit = 100;

final aiCoachHistoryProvider = NotifierProvider<AiCoachHistory, IList<AiCoachHistoryEntry>>(
  AiCoachHistory.new,
);

class AiCoachHistory() extends Notifier<IList<AiCoachHistoryEntry>> {
  Future<void> _pending = Future<void>.value();

  @override
  IList<AiCoachHistoryEntry> build() {
    final stored = LichessBinding.instance.sharedPreferences.getString(aiCoachHistoryStorageKey);
    if (stored == null) return const IListConst([]);
    try {
      final entries = jsonDecode(stored) as List<dynamic>;
      final history = <AiCoachHistoryEntry>[];
      for (final entry in entries.take(aiCoachHistoryLimit)) {
        try {
          final data = entry as Map<String, dynamic>;
          history.add((
            savedAt: DateTime.parse(data['savedAt'] as String),
            model: data['model'] as String,
            evidence: data['evidence'] as String,
            explanation: data['explanation'] as String,
            // Entries saved before follow-ups existed have none.
            followUps: _readFollowUps(data['followUps']),
          ));
        } on Object {
          // A malformed record must not hide the rest of the saved history.
          continue;
        }
      }
      return history.toIList();
    } on Object {
      return const IListConst([]);
    }
  }

  static IList<AiCoachFollowUp> _readFollowUps(Object? raw) {
    if (raw is! List<dynamic>) return const IListConst([]);
    final followUps = <AiCoachFollowUp>[];
    for (final item in raw) {
      try {
        final data = item as Map<String, dynamic>;
        followUps.add((question: data['question'] as String, answer: data['answer'] as String));
      } on Object {
        continue;
      }
    }
    return followUps.toIList();
  }

  /// The saved entry for exactly this [model] and [evidence], if any.
  AiCoachHistoryEntry? entryFor({required String model, required String evidence}) =>
      state.where((entry) => entry.model == model && entry.evidence == evidence).firstOrNull;

  String? find({required String model, required String evidence}) =>
      entryFor(model: model, evidence: evidence)?.explanation;

  Future<void> save({
    required String model,
    required String evidence,
    required String explanation,
  }) => _update(
    (current) => <AiCoachHistoryEntry>[
      (
        savedAt: DateTime.now().toUtc(),
        model: model,
        evidence: evidence,
        explanation: explanation,
        followUps: const IListConst([]),
      ),
      ...current.where((entry) => entry.model != model || entry.evidence != evidence),
    ].take(aiCoachHistoryLimit).toIList(),
  );

  /// Adds a follow-up to the saved explanation for [model] and [evidence]. Does nothing when that
  /// explanation is not saved (it may have been deleted meanwhile).
  Future<void> addFollowUp({
    required String model,
    required String evidence,
    required String question,
    required String answer,
  }) => _update(
    (current) => current
        .map(
          (entry) => entry.model == model && entry.evidence == evidence
              ? (
                  savedAt: entry.savedAt,
                  model: entry.model,
                  evidence: entry.evidence,
                  explanation: entry.explanation,
                  followUps: entry.followUps.add((question: question, answer: answer)),
                )
              : entry,
        )
        .toIList(),
  );

  Future<void> delete(AiCoachHistoryEntry entry) =>
      _update((current) => current.where((item) => item != entry).toIList());

  Future<void> clear() => _update((current) => const IListConst([]));

  /// Serialize writes so simultaneous saves/deletes cannot overwrite each other.
  /// Only publish state after storage confirms success; failed writes remain retryable.
  Future<void> _update(IList<AiCoachHistoryEntry> Function(IList<AiCoachHistoryEntry>) change) {
    final result = _pending.then((_) async {
      final next = change(state);
      await LichessBinding.instance.sharedPreferences.setString(
        aiCoachHistoryStorageKey,
        jsonEncode(
          next
              .map(
                (entry) => {
                  'savedAt': entry.savedAt.toIso8601String(),
                  'model': entry.model,
                  'evidence': entry.evidence,
                  'explanation': entry.explanation,
                  'followUps': entry.followUps
                      .map((f) => {'question': f.question, 'answer': f.answer})
                      .toList(),
                },
              )
              .toList(),
        ),
      );
      state = next;
    });
    _pending = result.catchError((Object error) {});
    return result;
  }
}
