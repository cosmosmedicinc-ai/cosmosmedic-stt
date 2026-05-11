import 'dart:async';

import 'package:flutter/material.dart';

import 'config.dart';
import 'models/language_pair.dart';
import 'services/realtime_translation_service.dart';

void main() {
  runApp(const MediBridgeApp());
}

class MediBridgeApp extends StatelessWidget {
  const MediBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MediBridge Realtime',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final RealtimeTranslationService _realtimeService =
      RealtimeTranslationService();

  LanguagePair _selectedLanguagePair = languagePairs.first;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  CaptionState _captions = const CaptionState();
  String _errorMessage = '';

  bool get _canStart =>
      _status == ConnectionStatus.disconnected ||
      _status == ConnectionStatus.error;

  bool get _canStop =>
      _status == ConnectionStatus.connecting ||
      _status == ConnectionStatus.connected ||
      _status == ConnectionStatus.listening;

  @override
  void initState() {
    super.initState();
    debugPrint('MediBridge autostart: ${AppConfig.autoStart}');
    if (AppConfig.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        debugPrint('MediBridge autostart callback: mounted=$mounted');
        if (mounted) {
          unawaited(_start());
        }
      });
    }
  }

  @override
  void dispose() {
    unawaited(_realtimeService.dispose());
    super.dispose();
  }

  Future<void> _start() async {
    debugPrint('MediBridge start pressed');
    setState(() {
      _status = ConnectionStatus.connecting;
      _captions = const CaptionState();
      _errorMessage = '';
    });

    try {
      debugPrint('MediBridge start: calling realtime service');
      await _realtimeService.start(
        languagePair: _selectedLanguagePair,
        onStatusChanged: (status) {
          if (!mounted) return;
          setState(() {
            _status = status;
          });
        },
        onCaptionChanged: (captions) {
          if (!mounted) return;
          setState(() {
            _captions = captions;
          });
        },
        onError: (message) {
          if (!mounted) return;
          setState(() {
            _errorMessage = message;
          });
        },
      );
    } catch (_) {
      debugPrint('MediBridge start: outer catch');
      if (!mounted) return;
      setState(() {
        _status = ConnectionStatus.error;
        _errorMessage = 'Failed to start realtime session.';
      });
    }
  }

  Future<void> _stop() async {
    await _realtimeService.disconnect();
    setState(() {
      _status = ConnectionStatus.disconnected;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MediBridge Realtime')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<LanguagePair>(
              initialValue: _selectedLanguagePair,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Language',
                border: OutlineInputBorder(),
              ),
              items: languagePairs
                  .map(
                    (pair) => DropdownMenuItem(
                      value: pair,
                      child: Text(pair.label),
                    ),
                  )
                  .toList(),
              onChanged: _canStart
                  ? (pair) {
                      if (pair == null) return;
                      setState(() {
                        _selectedLanguagePair = pair;
                      });
                    }
                  : null,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _canStart ? _start : null,
                    child: const Text('Start'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _canStop
                        ? () {
                            unawaited(_stop());
                          }
                        : null,
                    child: const Text('Stop'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _StatusPanel(status: _status),
            const SizedBox(height: 16),
            _TranscriptPanel(
              title: 'Recent original',
              text: _captions.originalText,
              isFinal: _captions.originalIsFinal,
              placeholder: 'Original speech will appear here.',
            ),
            const SizedBox(height: 12),
            _TranscriptPanel(
              title: 'Recent translation',
              text: _captions.translatedText,
              isFinal: _captions.translatedIsFinal,
              placeholder: 'Translation will appear here.',
            ),
            const SizedBox(height: 12),
            _ErrorPanel(message: _errorMessage),
          ],
        ),
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.status});

  final ConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'Status: ${status.name}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
    );
  }
}

class _TranscriptPanel extends StatelessWidget {
  const _TranscriptPanel({
    required this.title,
    required this.text,
    required this.isFinal,
    required this.placeholder,
  });

  final String title;
  final String text;
  final bool isFinal;
  final String placeholder;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 140),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Text(
                text.isEmpty ? '' : (isFinal ? 'final' : 'partial'),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            text.isEmpty ? placeholder : text,
            style: TextStyle(
              color: text.isEmpty
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.error),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message.isEmpty ? 'No errors.' : message,
        style: TextStyle(
          color: message.isEmpty
              ? Theme.of(context).colorScheme.onSurfaceVariant
              : Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }
}
