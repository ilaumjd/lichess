import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/db/secure_storage.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_history.dart';
import 'package:lichess_mobile/src/utils/navigation.dart';
import 'package:lichess_mobile/src/view/analysis/ai_coach_history_screen.dart';
import 'package:lichess_mobile/src/view/settings/ai_coach_settings_screen.dart';
import 'package:lichess_mobile/src/widgets/platform.dart';
import 'package:material_ui/material_ui.dart';

/// Immutable evidence avoids explaining a different position if the board changes mid-request.
class const AiCoachScreen({required final AiCoachRequest request, super.key})
    extends ConsumerStatefulWidget {
  static Route<void> buildRoute({required AiCoachRequest request}) =>
      buildScreenRoute(screen: AiCoachScreen(request: request));

  @override
  ConsumerState<AiCoachScreen> createState() => _AiCoachScreenState();
}

class _AiCoachScreenState() extends ConsumerState<AiCoachScreen> {
  bool _busy = false;
  String? _answer;
  String? _error;

  Future<void> _explain() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final model =
          await SecureStorage.instance.read(key: aiCoachModelStorage) ?? aiCoachDefaultModel;
      if (!mounted) return;
      final history = ref.read(aiCoachHistoryProvider.notifier);
      final saved = history.find(model: model, evidence: widget.request.evidence);
      if (saved != null) {
        setState(() {
          _answer = saved;
          _busy = false;
        });
        return;
      }
      final key = await SecureStorage.instance.read(key: aiCoachKeyStorage) ?? '';
      if (!mounted) return;
      final coach = ref.read(aiCoachProvider);
      final answer = await coach.explain(
        apiKey: key,
        model: model,
        evidence: widget.request.evidence,
        allowedMoves: widget.request.allowedMoves,
      );
      String? saveError;
      try {
        await history.save(model: model, evidence: widget.request.evidence, explanation: answer);
      } on Object {
        saveError = 'Explanation received, but it could not be saved on this device.';
      }
      if (mounted) {
        setState(() {
          _answer = answer;
          _error = saveError;
          _busy = false;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error is AiCoachException ? error.message : 'Could not read AI coach settings.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PlatformScaffold(
    appBar: const PlatformAppBar(title: Text('Explain position')),
    body: ListView(
      padding: const EdgeInsets.all(16).add(MediaQuery.paddingOf(context)),
      children: [
        const Text('Beginner coach', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        const Text(
          'Tapping Explain sends the position and engine evidence below directly to '
          'OpenAI using your API key. Charges may apply. Nothing is sent automatically. '
          'Stockfish supplies the moves; the AI tries to explain them and may make mistakes. '
          'Successful explanations are saved on this device. If this exact evidence and model '
          'are already saved, the answer is opened without an API request.',
        ),
        const SizedBox(height: 12),
        ExpansionTile(
          title: const Text('Position and engine evidence'),
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(widget.request.evidence),
            ),
          ],
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => Navigator.of(context).push(AiCoachSettingsScreen.buildRoute()),
          child: const Text('AI coach settings'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).push(AiCoachHistoryScreen.buildRoute()),
          child: const Text('Explanation history'),
        ),
        FilledButton(
          onPressed: _busy ? null : _explain,
          child: Text(_answer == null ? 'Explain' : 'Show saved explanation'),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (_error != null)
          Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(_error!)),
        if (_answer != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: SelectableText(_answer!),
          ),
      ],
    ),
  );
}
