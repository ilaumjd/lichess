import 'dart:convert';

import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/binding.dart';

/// Immutable, device-local study history. No credentials are stored with an explanation.
typedef AiCoachHistoryEntry = ({
  DateTime savedAt,
  String model,
  String evidence,
  String explanation,
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

  String? find({required String model, required String evidence}) => state
      .where((entry) => entry.model == model && entry.evidence == evidence)
      .firstOrNull
      ?.explanation;

  Future<void> save({
    required String model,
    required String evidence,
    required String explanation,
  }) => _update(
    (current) => <AiCoachHistoryEntry>[
      (savedAt: DateTime.now().toUtc(), model: model, evidence: evidence, explanation: explanation),
      ...current.where((entry) => entry.model != model || entry.evidence != evidence),
    ].take(aiCoachHistoryLimit).toIList(),
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
