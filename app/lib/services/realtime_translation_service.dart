import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart' hide IosAudioCategory;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config.dart';
import '../models/language_pair.dart';

enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  listening,
  error,
}

typedef StatusChanged = void Function(ConnectionStatus status);
typedef ConversationChanged = void Function(ConversationState conversation);
typedef ErrorChanged = void Function(String message);

class RealtimeTranslationService {
  RealtimeTranslationService({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  static const _inputSampleRate = 16000;
  static const _outputSampleRate = 24000;
  static const _audioMimeType = 'audio/pcm;rate=$_inputSampleRate';

  final http.Client _httpClient;
  final AudioRecorder _recorder = AudioRecorder();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socketSubscription;
  StreamSubscription<Uint8List>? _audioSubscription;
  bool _connected = false;
  bool _audioPlayerReady = false;
  ConversationState _conversation = const ConversationState();

  Future<void> start({
    required LanguagePair languagePair,
    required StatusChanged onStatusChanged,
    required ConversationChanged onConversationChanged,
    required ErrorChanged onError,
  }) async {
    try {
      await disconnect();
      _conversation = const ConversationState();
      onStatusChanged(ConnectionStatus.connecting);

      debugPrint('Gemini Live start: checking microphone permission');
      await _ensureMicrophonePermission();
      await _ensureAudioPlayerReady();

      debugPrint(
        'Gemini Live start: pair ${languagePair.primaryLanguage}<->${languagePair.secondaryLanguage}',
      );
      final session = await _createSession(languagePair);

      debugPrint('Gemini Live start: opening websocket');
      final channel = IOWebSocketChannel.connect(
        Uri.parse(session.websocketUrl),
        pingInterval: const Duration(seconds: 20),
      );
      _channel = channel;
      _connected = true;

      _socketSubscription = channel.stream.listen(
        (message) {
          _handleServerMessage(
            message,
            onStatusChanged: onStatusChanged,
            onConversationChanged: onConversationChanged,
            onError: onError,
          );
        },
        onError: (Object error) {
          debugPrint(
              'Gemini Live websocket error: ${_safeErrorMessage(error)}');
          onStatusChanged(ConnectionStatus.error);
          onError(_safeUserMessage(error));
        },
        onDone: () {
          _connected = false;
          onStatusChanged(ConnectionStatus.disconnected);
        },
      );

      channel.sink.add(jsonEncode(session.setupMessage));
      onStatusChanged(ConnectionStatus.connected);
      await _startMicrophoneStream();
      onStatusChanged(ConnectionStatus.listening);
    } catch (error) {
      debugPrint('Gemini Live connection failed: ${_safeErrorMessage(error)}');
      await disconnect();
      onStatusChanged(ConnectionStatus.error);
      onError(_safeUserMessage(error));
    }
  }

  Future<void> disconnect() async {
    _connected = false;

    await _audioSubscription?.cancel();
    _audioSubscription = null;
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }

    final channel = _channel;
    _channel = null;
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    await channel?.sink.close();

    if (_audioPlayerReady) {
      await FlutterPcmSound.release();
      _audioPlayerReady = false;
    }

    _conversation = const ConversationState();
  }

  Future<void> dispose() async {
    await disconnect();
    await _recorder.dispose();
    _httpClient.close();
  }

  Future<void> _ensureMicrophonePermission() async {
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        throw const RealtimeTranslationException(
          'Microphone permission denied.',
        );
      }
    }

    if (!await _recorder.hasPermission()) {
      throw const RealtimeTranslationException(
        'Microphone permission denied.',
      );
    }
  }

  Future<void> _ensureAudioPlayerReady() async {
    if (_audioPlayerReady) {
      return;
    }

    await FlutterPcmSound.setLogLevel(LogLevel.error);
    await FlutterPcmSound.setup(
      sampleRate: _outputSampleRate,
      channelCount: 1,
      iosAudioCategory: IosAudioCategory.playAndRecord,
    );
    await FlutterPcmSound.setFeedThreshold(_outputSampleRate ~/ 8);
    _audioPlayerReady = true;
  }

  Future<SessionConnectionData> _createSession(
      LanguagePair languagePair) async {
    final response = await _httpClient.post(
      Uri.parse('${AppConfig.serverUrl}/session'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'primaryLanguage': languagePair.primaryLanguage,
        'secondaryLanguage': languagePair.secondaryLanguage,
      }),
    );

    final body = _decodeJsonObject(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RealtimeTranslationException(
        'Session request failed with ${response.statusCode}.',
      );
    }

    final websocketUrl = body['websocketUrl'];
    final setup = body['setup'];
    if (websocketUrl is! String || websocketUrl.isEmpty) {
      throw const RealtimeTranslationException(
        'Session response did not include a Gemini websocket URL.',
      );
    }
    if (setup is! Map<String, dynamic>) {
      throw const RealtimeTranslationException(
        'Session response did not include Gemini setup data.',
      );
    }

    return SessionConnectionData(
      websocketUrl: websocketUrl,
      setupMessage: setup,
    );
  }

  Future<void> _startMicrophoneStream() async {
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _inputSampleRate,
        numChannels: 1,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
        streamBufferSize: 3200,
      ),
    );

    _audioSubscription = stream.listen((chunk) {
      if (!_connected || chunk.isEmpty) {
        return;
      }

      _channel?.sink.add(jsonEncode({
        'realtimeInput': {
          'audio': {
            'data': base64Encode(chunk),
            'mimeType': _audioMimeType,
          },
        },
      }));
    });
  }

  void _handleServerMessage(
    dynamic message, {
    required StatusChanged onStatusChanged,
    required ConversationChanged onConversationChanged,
    required ErrorChanged onError,
  }) {
    final event = _decodeJsonObject(message is String ? message : '');
    if (event.isEmpty) {
      debugPrint('Gemini Live non-JSON websocket message ignored.');
      return;
    }

    if (event.containsKey('setupComplete')) {
      debugPrint('Gemini Live setup complete.');
      onStatusChanged(ConnectionStatus.listening);
      return;
    }

    final serverContent = event['serverContent'];
    if (serverContent is Map<String, dynamic>) {
      _handleServerContent(
        serverContent,
        onConversationChanged: onConversationChanged,
      );
      return;
    }

    if (event.containsKey('goAway')) {
      debugPrint('Gemini Live goAway received.');
      onError('Realtime session is ending soon.');
      return;
    }

    if (event.containsKey('usageMetadata')) {
      return;
    }

    debugPrint('Unhandled Gemini Live event keys: ${event.keys.join(",")}');
  }

  void _handleServerContent(
    Map<String, dynamic> content, {
    required ConversationChanged onConversationChanged,
  }) {
    final inputText = _readTranscriptionText(content['inputTranscription']);
    if (inputText.isNotEmpty) {
      _mergeCurrentOriginal(inputText);
      onConversationChanged(_conversation);
    }

    final outputText = _readTranscriptionText(content['outputTranscription']);
    if (outputText.isNotEmpty) {
      _mergeCurrentTranslation(outputText);
      onConversationChanged(_conversation);
    }

    final modelText = _readModelTurnText(content['modelTurn']);
    if (modelText.isNotEmpty) {
      _mergeCurrentTranslation(modelText);
      onConversationChanged(_conversation);
    }

    final audioChunks = _readModelTurnAudio(content['modelTurn']);
    for (final chunk in audioChunks) {
      unawaited(_playAudioChunk(chunk));
    }

    if (content['interrupted'] == true) {
      _conversation = _conversation.copyWith(currentTranslationText: '');
      onConversationChanged(_conversation);
    }

    if (content['turnComplete'] == true) {
      _commitCurrentTurn();
      onConversationChanged(_conversation);
    }
  }

  Future<void> _playAudioChunk(Uint8List chunk) async {
    if (chunk.isEmpty || !_audioPlayerReady) {
      return;
    }

    await FlutterPcmSound.feed(
      PcmArrayInt16(
        bytes: chunk.buffer.asByteData(
          chunk.offsetInBytes,
          chunk.lengthInBytes,
        ),
      ),
    );
    FlutterPcmSound.start();
  }

  void _mergeCurrentOriginal(String text) {
    final next = text.trim();
    if (next.isEmpty) {
      return;
    }

    final current = _conversation.currentOriginalText.trim();
    _conversation = _conversation.copyWith(
      currentOriginalText: _mergeIncrementalText(current, next),
      currentOriginalIsFinal: false,
    );
  }

  void _mergeCurrentTranslation(String text) {
    final next = text.trim();
    if (next.isEmpty) {
      return;
    }

    final current = _conversation.currentTranslationText.trim();
    _conversation = _conversation.copyWith(
      currentTranslationText: _mergeIncrementalText(current, next),
      currentTranslationIsFinal: false,
    );
  }

  String _mergeIncrementalText(String current, String next) {
    if (current.isEmpty ||
        next.startsWith(current) ||
        _sameText(current, next)) {
      return next;
    }

    if (current.startsWith(next)) {
      return current;
    }

    return '$current $next';
  }

  void _commitCurrentTurn() {
    final original = _conversation.currentOriginalText.trim();
    final translation = _conversation.currentTranslationText.trim();

    if (original.isEmpty || translation.isEmpty) {
      _conversation = _conversation.copyWith(
        currentOriginalIsFinal: original.isNotEmpty,
        currentTranslationIsFinal: translation.isNotEmpty,
      );
      return;
    }

    final lastTurn =
        _conversation.turns.isEmpty ? null : _conversation.turns.last;
    if (lastTurn != null &&
        _sameText(lastTurn.originalText, original) &&
        _sameText(lastTurn.translatedText, translation)) {
      _conversation = ConversationState(turns: _conversation.turns);
      return;
    }

    final turns = [
      ..._conversation.turns,
      ConversationTurn(
        originalText: original,
        translatedText: translation,
        createdAt: DateTime.now(),
      ),
    ];

    _conversation = ConversationState(
      turns: turns.length > 20 ? turns.sublist(turns.length - 20) : turns,
    );
  }

  bool _sameText(String left, String right) {
    return left.trim().replaceAll(RegExp(r'\s+'), ' ') ==
        right.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  String _readTranscriptionText(dynamic value) {
    if (value is! Map<String, dynamic>) {
      return '';
    }

    final text = value['text'];
    return text is String ? text : '';
  }

  String _readModelTurnText(dynamic value) {
    if (value is! Map<String, dynamic>) {
      return '';
    }

    final contentParts = value['parts'];
    if (contentParts is! List) {
      return '';
    }

    final parts = <String>[];
    for (final part in contentParts) {
      if (part is! Map<String, dynamic>) {
        continue;
      }

      final text = part['text'];
      if (text is String && text.isNotEmpty) {
        parts.add(text);
      }
    }

    return parts.join(' ');
  }

  List<Uint8List> _readModelTurnAudio(dynamic value) {
    if (value is! Map<String, dynamic>) {
      return const [];
    }

    final contentParts = value['parts'];
    if (contentParts is! List) {
      return const [];
    }

    final chunks = <Uint8List>[];
    for (final part in contentParts) {
      if (part is! Map<String, dynamic>) {
        continue;
      }

      final inlineData = part['inlineData'];
      if (inlineData is! Map<String, dynamic>) {
        continue;
      }

      final data = inlineData['data'];
      final mimeType = inlineData['mimeType'];
      if (data is String &&
          data.isNotEmpty &&
          mimeType is String &&
          mimeType.startsWith('audio/')) {
        try {
          chunks.add(base64Decode(data));
        } catch (_) {
          debugPrint('Gemini Live audio chunk decode failed.');
        }
      }
    }

    return chunks;
  }

  Map<String, dynamic> _decodeJsonObject(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      return {};
    }

    return {};
  }

  String _safeErrorMessage(Object error) {
    if (error is RealtimeTranslationException) {
      return error.message;
    }

    return error.toString();
  }

  String _safeUserMessage(Object error) {
    if (error is RealtimeTranslationException) {
      return error.message;
    }

    final message = error.toString();
    if (message.isEmpty) {
      return 'Realtime connection failed.';
    }

    return message.length > 180 ? '${message.substring(0, 180)}...' : message;
  }
}

class SessionConnectionData {
  const SessionConnectionData({
    required this.websocketUrl,
    required this.setupMessage,
  });

  final String websocketUrl;
  final Map<String, dynamic> setupMessage;
}

class ConversationState {
  const ConversationState({
    this.turns = const [],
    this.currentOriginalText = '',
    this.currentTranslationText = '',
    this.currentOriginalIsFinal = false,
    this.currentTranslationIsFinal = false,
  });

  final List<ConversationTurn> turns;
  final String currentOriginalText;
  final String currentTranslationText;
  final bool currentOriginalIsFinal;
  final bool currentTranslationIsFinal;

  bool get hasCurrent => currentOriginalText.isNotEmpty;

  ConversationState copyWith({
    List<ConversationTurn>? turns,
    String? currentOriginalText,
    String? currentTranslationText,
    bool? currentOriginalIsFinal,
    bool? currentTranslationIsFinal,
  }) {
    return ConversationState(
      turns: turns ?? this.turns,
      currentOriginalText: currentOriginalText ?? this.currentOriginalText,
      currentTranslationText:
          currentTranslationText ?? this.currentTranslationText,
      currentOriginalIsFinal:
          currentOriginalIsFinal ?? this.currentOriginalIsFinal,
      currentTranslationIsFinal:
          currentTranslationIsFinal ?? this.currentTranslationIsFinal,
    );
  }
}

class ConversationTurn {
  const ConversationTurn({
    required this.originalText,
    required this.translatedText,
    required this.createdAt,
  });

  final String originalText;
  final String translatedText;
  final DateTime createdAt;
}

class RealtimeTranslationException implements Exception {
  const RealtimeTranslationException(this.message);

  final String message;
}
