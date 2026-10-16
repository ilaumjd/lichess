import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/db/secure_storage.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/utils/navigation.dart';
import 'package:lichess_mobile/src/view/settings/ai_coach_settings_screen.dart';
import 'package:lichess_mobile/src/widgets/platform.dart';
import 'package:material_ui/material_ui.dart';

/// Immutable evidence avoids explaining a different position if the board changes mid-request.
class const AiCoachScreen({required final String evidence, super.key})
    extends ConsumerStatefulWidget {
  static Route<void> buildRoute({required String evidence}) =>
      buildScreenRoute(screen: AiCoachScreen(evidence: evidence));

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
      final key = await SecureStorage.instance.read(key: aiCoachKeyStorage) ?? '';
      final model =
          await SecureStorage.instance.read(key: aiCoachModelStorage) ?? aiCoachDefaultModel;
      if (!mounted) return;
      final answer = await ref
          .read(aiCoachProvider)
          .explain(apiKey: key, model: model, evidence: widget.evidence);
      if (mounted) {
        setState(() {
          _answer = answer;
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
          'Stockfish supplies the moves; the AI tries to explain them and may make mistakes.',
        ),
        const SizedBox(height: 12),
        ExpansionTile(
          title: const Text('Position and engine evidence'),
          children: [
            Padding(padding: const EdgeInsets.all(12), child: SelectableText(widget.evidence)),
          ],
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => Navigator.of(context).push(AiCoachSettingsScreen.buildRoute()),
          child: const Text('AI coach settings'),
        ),
        FilledButton(
          onPressed: _busy ? null : _explain,
          child: Text(_answer == null ? 'Explain' : 'Show cached explanation'),
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
