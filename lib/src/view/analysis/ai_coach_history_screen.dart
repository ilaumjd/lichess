import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_boards.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_history.dart';
import 'package:lichess_mobile/src/utils/navigation.dart';
import 'package:lichess_mobile/src/view/analysis/ai_coach_boards_view.dart';
import 'package:lichess_mobile/src/widgets/platform.dart';
import 'package:material_ui/material_ui.dart';

class const AiCoachHistoryScreen({super.key}) extends ConsumerWidget {
  static Route<void> buildRoute() => buildScreenRoute(screen: const AiCoachHistoryScreen());

  Future<void> _delete(BuildContext context, WidgetRef ref, AiCoachHistoryEntry? entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(entry == null ? 'Clear explanation history?' : 'Delete this explanation?'),
        content: const Text(
          'This removes the saved explanation from this app. It cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final history = ref.read(aiCoachHistoryProvider.notifier);
      if (entry == null) {
        await history.clear();
      } else {
        await history.delete(entry);
      }
      ref.read(aiCoachProvider).clearCache();
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update saved history on this device.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(aiCoachHistoryProvider);
    return PlatformScaffold(
      appBar: const PlatformAppBar(title: Text('Explanation history')),
      body: ListView(
        padding: const EdgeInsets.all(16).add(MediaQuery.paddingOf(context)),
        children: [
          const Text(
            'Saved on this device. The newest 100 explanations are kept. '
            'Opening history works offline and never calls OpenAI. '
            'Your API key is not included. These are AI study notes and may contain mistakes.',
          ),
          if (history.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('No saved explanations yet.'),
            ),
          if (history.isNotEmpty)
            TextButton(
              onPressed: () => _delete(context, ref, null),
              child: const Text('Clear history'),
            ),
          for (final entry in history)
            ListTile(
              title: Text(entry.explanation, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${entry.savedAt.toLocal().toString().split('.').first} · ${entry.model}',
              ),
              trailing: IconButton(
                tooltip: 'Delete explanation',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _delete(context, ref, entry),
              ),
              onTap: () => Navigator.of(context)
                  .push(buildScreenRoute<void>(screen: AiCoachHistoryDetailScreen(entry: entry))),
            ),
        ],
      ),
    );
  }
}

class const AiCoachHistoryDetailScreen({required final AiCoachHistoryEntry entry, super.key})
    extends StatelessWidget {
  @override
  Widget build(BuildContext context) => PlatformScaffold(
    appBar: const PlatformAppBar(title: Text('Saved explanation')),
    body: ListView(
      padding: const EdgeInsets.all(16).add(MediaQuery.paddingOf(context)),
      children: [
        Text('${entry.savedAt.toLocal().toString().split('.').first} · ${entry.model}'),
        const SizedBox(height: 16),
        if (aiCoachBoardsFromEvidence(entry.evidence) case final boards?) ...[
          AiCoachBoardsView(boards: boards),
          const SizedBox(height: 16),
        ],
        SelectableText(entry.explanation),
        const SizedBox(height: 16),
        for (final turn in entry.followUps) ...[
          Text('You: ${turn.question}', style: const TextStyle(fontWeight: FontWeight.bold)),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 16),
            child: SelectableText(turn.answer),
          ),
        ],
        ExpansionTile(
          title: const Text('Position and engine evidence'),
          children: [
            Padding(padding: const EdgeInsets.all(12), child: SelectableText(entry.evidence)),
          ],
        ),
      ],
    ),
  );
}
