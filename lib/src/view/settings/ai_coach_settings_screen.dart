import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/db/secure_storage.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_level.dart';
import 'package:lichess_mobile/src/utils/navigation.dart';
import 'package:lichess_mobile/src/view/analysis/ai_coach_history_screen.dart';
import 'package:lichess_mobile/src/widgets/platform.dart';
import 'package:material_ui/material_ui.dart';

const aiCoachKeyStorage = 'aiCoach.openaiKey';
const aiCoachModelStorage = 'aiCoach.model';
const aiCoachDefaultModel = 'gpt-6-luna';

class const AiCoachSettingsScreen({super.key}) extends ConsumerStatefulWidget {
  static Route<void> buildRoute() => buildScreenRoute(screen: const AiCoachSettingsScreen());

  @override
  ConsumerState<AiCoachSettingsScreen> createState() => _AiCoachSettingsScreenState();
}

class _AiCoachSettingsScreenState() extends ConsumerState<AiCoachSettingsScreen> {
  final _key = TextEditingController();
  final _model = TextEditingController(text: aiCoachDefaultModel);
  bool _busy = true;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final key = await SecureStorage.instance.read(key: aiCoachKeyStorage);
      final model = await SecureStorage.instance.read(key: aiCoachModelStorage);
      if (!mounted) return;
      _key.text = key ?? '';
      _model.text = model ?? aiCoachDefaultModel;
      setState(() => _busy = false);
    } on Object {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = 'Could not open secure storage.';
        });
      }
    }
  }

  Future<void> _setLevel(AiCoachLevel level) async {
    try {
      await ref.read(aiCoachLevelProvider.notifier).set(level);
    } on Object {
      if (mounted) setState(() => _status = 'Could not save the coach level.');
    }
  }

  Future<void> _save({bool remove = false}) async {
    if (!remove && (_key.text.trim().isEmpty || _model.text.trim().isEmpty)) {
      setState(() => _status = 'Enter an API key and a model name.');
      return;
    }
    setState(() => _busy = true);
    try {
      if (remove) {
        await SecureStorage.instance.delete(key: aiCoachKeyStorage);
        await SecureStorage.instance.delete(key: aiCoachModelStorage);
      } else {
        await SecureStorage.instance.write(key: aiCoachKeyStorage, value: _key.text.trim());
        await SecureStorage.instance.write(key: aiCoachModelStorage, value: _model.text.trim());
      }
      ref.read(aiCoachProvider).clearCache();
      if (!mounted) return;
      if (remove) _key.clear();
      setState(() {
        _busy = false;
        _status = remove ? 'API key removed.' : 'Saved securely.';
      });
    } on Object {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = 'Could not save settings securely.';
        });
      }
    }
  }

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlatformScaffold(
    appBar: const PlatformAppBar(title: Text('AI coach settings')),
    body: ListView(
      padding: const EdgeInsets.all(16).add(MediaQuery.paddingOf(context)),
      children: [
        const Text(
          'Optional explanations powered by OpenAI. Stockfish stays on your '
          'phone. Only when you tap Explain, the current FEN, move history and engine lines are '
          'sent directly to OpenAI. API usage is billed separately from ChatGPT subscriptions. '
          'AI explanations can be wrong. Never use them for assistance in live games.',
        ),
        TextButton(
          onPressed: () => Navigator.of(context).push(AiCoachHistoryScreen.buildRoute()),
          child: const Text('Explanation history'),
        ),
        const SizedBox(height: 20),
        const Text('Coach level', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final level in AiCoachLevel.values)
              ChoiceChip(
                label: Text(level.label),
                selected: level == ref.watch(aiCoachLevelProvider),
                onSelected: (_) => _setLevel(level),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(ref.watch(aiCoachLevelProvider).description),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _key,
          enabled: !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [],
          inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
          decoration: const InputDecoration(
            labelText: 'OpenAI API key',
            helperText: 'Stored in OS-backed secure storage, not ordinary preferences.',
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _model,
          enabled: !_busy,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'OpenAI model',
            helperText: 'For example: gpt-6-luna',
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(onPressed: _busy ? null : () => _save(), child: const Text('Save')),
        TextButton(
          onPressed: _busy ? null : () => _save(remove: true),
          child: const Text('Remove API key'),
        ),
        if (_busy) const Center(child: CircularProgressIndicator()),
        if (_status != null) Text(_status!),
      ],
    ),
  );
}
