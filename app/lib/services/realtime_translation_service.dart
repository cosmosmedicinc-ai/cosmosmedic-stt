import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

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

  final http.Client _httpClient;
  final RTCVideoRenderer _remoteAudioRenderer = RTCVideoRenderer();

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _eventsChannel;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  bool _rendererInitialized = false;
  ConversationState _conversation = const ConversationState();

  Future<void> start({
    required LanguagePair languagePair,
    required StatusChanged onStatusChanged,
    required ConversationChanged onConversationChanged,
    required ErrorChanged onError,
  }) async {
    try {
      await disconnect();
      onStatusChanged(ConnectionStatus.connecting);

      debugPrint('Realtime start: checking microphone permission');
      await _ensureMicrophonePermission();
      debugPrint('Realtime start: initializing remote audio renderer');
      await _ensureRendererInitialized();

      debugPrint(
        'Realtime start: pair ${languagePair.primaryLanguage}<->${languagePair.secondaryLanguage}',
      );
      debugPrint('Realtime start: requesting server session');
      final session = await _createSession(languagePair);
      debugPrint('Realtime start: creating peer connection');
      final peerConnection = await _createPeerConnection(
        onStatusChanged: onStatusChanged,
        onError: onError,
      );
      _peerConnection = peerConnection;

      debugPrint('Realtime start: requesting microphone stream');
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });

      final audioTracks = _localStream?.getAudioTracks() ?? [];
      if (audioTracks.isEmpty) {
        throw const RealtimeTranslationException('No microphone audio track.');
      }

      debugPrint('Realtime start: adding microphone track');
      await peerConnection.addTrack(audioTracks.first, _localStream!);
      debugPrint('Realtime start: creating data channel');
      _eventsChannel = await peerConnection.createDataChannel(
        'oai-events',
        RTCDataChannelInit()..ordered = true,
      );
      _eventsChannel?.onMessage = (message) {
        _handleDataChannelMessage(
          message.text,
          onConversationChanged: onConversationChanged,
          onError: onError,
        );
      };

      debugPrint('Realtime start: creating SDP offer');
      final offer = await peerConnection.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });
      await peerConnection.setLocalDescription(offer);
      debugPrint('Realtime start: waiting for ICE gathering');
      await _waitForIceGathering(peerConnection);

      final localDescription = await peerConnection.getLocalDescription();
      final offerSdp = localDescription?.sdp ?? offer.sdp;
      if (offerSdp == null || offerSdp.isEmpty) {
        throw const RealtimeTranslationException('Failed to create SDP offer.');
      }

      debugPrint('Realtime start: sending SDP offer to OpenAI');
      final answerSdp = await _sendOfferToOpenAi(
        callsUrl: session.callsUrl,
        clientSecret: session.clientSecret,
        offerSdp: offerSdp,
      );

      await peerConnection.setRemoteDescription(
        RTCSessionDescription(answerSdp, 'answer'),
      );
      debugPrint('Realtime start: remote SDP answer applied');
      onStatusChanged(ConnectionStatus.connected);
    } catch (error) {
      debugPrint('Realtime connection failed: ${_safeErrorMessage(error)}');
      await disconnect();
      onStatusChanged(ConnectionStatus.error);
      onError(_safeUserMessage(error));
    }
  }

  Future<void> disconnect() async {
    _eventsChannel?.onMessage = null;
    await _eventsChannel?.close();
    _eventsChannel = null;

    final localTracks = _localStream?.getTracks() ?? [];
    for (final track in localTracks) {
      await track.stop();
    }
    await _localStream?.dispose();
    _localStream = null;

    final remoteTracks = _remoteStream?.getTracks() ?? [];
    for (final track in remoteTracks) {
      await track.stop();
    }
    await _remoteStream?.dispose();
    _remoteStream = null;
    if (_rendererInitialized) {
      _remoteAudioRenderer.srcObject = null;
    }

    await _peerConnection?.close();
    await _peerConnection?.dispose();
    _peerConnection = null;

    _conversation = const ConversationState();
  }

  Future<void> dispose() async {
    await disconnect();
    if (_rendererInitialized) {
      await _remoteAudioRenderer.dispose();
      _rendererInitialized = false;
    }
    _httpClient.close();
  }

  Future<void> _ensureMicrophonePermission() async {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return;
    }

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      throw const RealtimeTranslationException('Microphone permission denied.');
    }
  }

  Future<void> _ensureRendererInitialized() async {
    if (_rendererInitialized) {
      return;
    }

    await _remoteAudioRenderer.initialize();
    _rendererInitialized = true;
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

    final clientSecret = _findClientSecret(body);
    if (clientSecret == null || clientSecret.isEmpty) {
      throw const RealtimeTranslationException(
        'Session response did not include a client secret.',
      );
    }

    final callsUrl = body['callsUrl'] as String? ??
        'https://api.openai.com/v1/realtime/calls';

    return SessionConnectionData(
      clientSecret: clientSecret,
      callsUrl: callsUrl,
    );
  }

  Future<RTCPeerConnection> _createPeerConnection({
    required StatusChanged onStatusChanged,
    required ErrorChanged onError,
  }) async {
    final peerConnection = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    });

    peerConnection.onTrack = (event) {
      if (event.streams.isEmpty) {
        return;
      }

      _remoteStream = event.streams.first;
      _remoteAudioRenderer.srcObject = _remoteStream;
      onStatusChanged(ConnectionStatus.listening);
    };

    peerConnection.onConnectionState = (state) {
      debugPrint('WebRTC connection state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onStatusChanged(ConnectionStatus.connected);
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        onStatusChanged(ConnectionStatus.error);
        onError('Realtime connection failed.');
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        onStatusChanged(ConnectionStatus.disconnected);
      }
    };

    return peerConnection;
  }

  Future<void> _waitForIceGathering(RTCPeerConnection peerConnection) async {
    final completer = Completer<void>();

    peerConnection.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !completer.isCompleted) {
        completer.complete();
      }
    };

    await Future.any([
      completer.future,
      Future<void>.delayed(const Duration(seconds: 3)),
    ]);
  }

  Future<String> _sendOfferToOpenAi({
    required String callsUrl,
    required String clientSecret,
    required String offerSdp,
  }) async {
    final response = await _httpClient.post(
      Uri.parse(callsUrl),
      headers: {
        'Authorization': 'Bearer $clientSecret',
        'Content-Type': 'application/sdp',
      },
      body: offerSdp,
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RealtimeTranslationException(
        'OpenAI SDP exchange failed with ${response.statusCode}.',
      );
    }

    if (response.body.isEmpty) {
      throw const RealtimeTranslationException('OpenAI returned an empty SDP.');
    }

    return response.body;
  }

  void _handleDataChannelMessage(
    String data, {
    required ConversationChanged onConversationChanged,
    required ErrorChanged onError,
  }) {
    final event = _decodeJsonObject(data);
    final type = event['type'] as String?;

    if (type == null || type.isEmpty) {
      debugPrint('Realtime data channel event without type ignored.');
      return;
    }

    switch (type) {
      case 'conversation.item.input_audio_transcription.delta':
      case 'session.input_transcript.delta':
        _appendCurrentOriginal(_readTextDelta(event));
        onConversationChanged(_conversation);
        break;
      case 'response.output_audio_transcript.delta':
      case 'response.output_text.delta':
      case 'session.output_transcript.delta':
        _appendCurrentTranslation(_readTextDelta(event));
        onConversationChanged(_conversation);
        break;
      case 'conversation.item.input_audio_transcription.completed':
      case 'session.input_transcript.completed':
      case 'session.input_transcript.done':
      case 'session.input_transcript.final':
        _finalizeCurrentOriginal(_readTranscriptText(event));
        onConversationChanged(_conversation);
        break;
      case 'conversation.item.done':
        if (_tryFinalizeConversationItem(event)) {
          onConversationChanged(_conversation);
        }
        break;
      case 'response.content_part.done':
        _finalizeCurrentTranslation(_readContentPartText(event));
        onConversationChanged(_conversation);
        break;
      case 'response.output_audio_transcript.done':
      case 'response.output_text.done':
      case 'session.output_transcript.completed':
      case 'session.output_transcript.done':
      case 'session.output_transcript.final':
        _finalizeCurrentTranslation(_readTranscriptText(event));
        onConversationChanged(_conversation);
        break;
      case 'response.output_item.done':
        _finalizeCurrentTranslation(_readConversationItemText(event));
        onConversationChanged(_conversation);
        break;
      case 'session.output_audio.delta':
      case 'session.output_audio.done':
        return;
      case 'error':
        debugPrint('Realtime data channel event type: error');
        onError('Realtime event error.');
        break;
      default:
        debugPrint('Unhandled Realtime data channel event type: $type');
    }
  }

  void _appendCurrentOriginal(String delta) {
    if (delta.isEmpty) {
      return;
    }

    final base = _conversation.currentOriginalIsFinal
        ? ''
        : _conversation.currentOriginalText;
    _conversation = _conversation.copyWith(
      currentOriginalText: base + delta,
      currentOriginalIsFinal: false,
    );
  }

  void _appendCurrentTranslation(String delta) {
    if (delta.isEmpty) {
      return;
    }

    final base = _conversation.currentTranslationIsFinal
        ? ''
        : _conversation.currentTranslationText;
    _conversation = _conversation.copyWith(
      currentTranslationText: base + delta,
      currentTranslationIsFinal: false,
    );
  }

  void _finalizeCurrentOriginal(String transcript) {
    _conversation = _conversation.copyWith(
      currentOriginalText:
          transcript.isEmpty ? _conversation.currentOriginalText : transcript,
      currentOriginalIsFinal: true,
    );
    _maybeCommitCurrentTurn();
  }

  void _finalizeCurrentTranslation(String transcript) {
    final translation =
        transcript.isEmpty ? _conversation.currentTranslationText : transcript;

    if (translation.isEmpty) {
      _conversation = _conversation.copyWith(
        currentTranslationIsFinal: true,
      );
      return;
    }

    _conversation = _conversation.copyWith(
      currentTranslationText: translation,
      currentTranslationIsFinal: true,
    );
    _maybeCommitCurrentTurn();
  }

  void _maybeCommitCurrentTurn() {
    final original = _conversation.currentOriginalText.trim();
    final translation = _conversation.currentTranslationText.trim();

    if (original.isEmpty || translation.isEmpty) {
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

  bool _tryFinalizeConversationItem(Map<String, dynamic> event) {
    final item = event['item'];
    if (item is! Map<String, dynamic>) {
      return false;
    }

    final role = item['role'];
    final text = _readConversationItemText(event);
    if (text.isEmpty) {
      return false;
    }

    if (role == 'user') {
      _finalizeCurrentOriginal(text);
      return true;
    }

    if (role == 'assistant') {
      _finalizeCurrentTranslation(text);
      return true;
    }

    return false;
  }

  String _readTextDelta(Map<String, dynamic> event) {
    final delta = event['delta'];
    if (delta is String) {
      return _normalizeRealtimeText(delta);
    }

    final text = event['text'];
    if (text is String) {
      return _normalizeRealtimeText(text);
    }

    return '';
  }

  String _readTranscriptText(Map<String, dynamic> event) {
    final transcript = event['transcript'];
    if (transcript is String) {
      return _normalizeRealtimeText(transcript);
    }

    final text = event['text'];
    if (text is String) {
      return _normalizeRealtimeText(text);
    }

    final delta = event['delta'];
    if (delta is String) {
      return _normalizeRealtimeText(delta);
    }

    return '';
  }

  String _readContentPartText(Map<String, dynamic> event) {
    final part = event['part'];
    if (part is! Map<String, dynamic>) {
      return '';
    }

    final transcript = part['transcript'];
    if (transcript is String) {
      return _normalizeRealtimeText(transcript);
    }

    final text = part['text'];
    if (text is String) {
      return _normalizeRealtimeText(text);
    }

    return '';
  }

  String _readConversationItemText(Map<String, dynamic> event) {
    final item = event['item'];
    if (item is! Map<String, dynamic>) {
      return '';
    }

    final content = item['content'];
    if (content is! List) {
      return '';
    }

    final parts = <String>[];
    for (final part in content) {
      if (part is! Map<String, dynamic>) {
        continue;
      }

      final transcript = part['transcript'];
      if (transcript is String && transcript.isNotEmpty) {
        parts.add(_normalizeRealtimeText(transcript));
        continue;
      }

      final text = part['text'];
      if (text is String && text.isNotEmpty) {
        parts.add(_normalizeRealtimeText(text));
      }
    }

    return parts.join('\n');
  }

  String _normalizeRealtimeText(String value) {
    if (!_looksLikeMojibake(value)) {
      return value;
    }

    final bytes = <int>[];
    for (final rune in value.runes) {
      if (rune <= 0xff) {
        bytes.add(rune);
        continue;
      }

      final byte = _windows1252ByteByRune[rune];
      if (byte == null) {
        return value;
      }
      bytes.add(byte);
    }

    try {
      final repaired = utf8.decode(bytes);
      return _mojibakeScore(repaired) < _mojibakeScore(value)
          ? repaired
          : value;
    } catch (_) {
      return value;
    }
  }

  bool _looksLikeMojibake(String value) {
    return value.runes.any(
      (rune) =>
          (rune >= 0x80 && rune <= 0x9f) ||
          rune == 0xc2 ||
          rune == 0xc3 ||
          rune == 0xec ||
          rune == 0xed ||
          rune == 0xea ||
          _windows1252ByteByRune.containsKey(rune),
    );
  }

  int _mojibakeScore(String value) {
    var score = 0;
    for (final rune in value.runes) {
      if (rune >= 0xac00 && rune <= 0xd7a3) {
        score -= 3;
      } else if (rune >= 0x80 && rune <= 0x9f) {
        score += 3;
      } else if (_windows1252ByteByRune.containsKey(rune)) {
        score += 2;
      } else if (rune == 0xfffd) {
        score += 5;
      }
    }
    return score;
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

  String? _findClientSecret(Map<String, dynamic> body) {
    final directValue = body['value'];
    if (directValue is String) {
      return directValue;
    }

    final clientSecret = body['client_secret'];
    if (clientSecret is Map<String, dynamic>) {
      final value = clientSecret['value'];
      if (value is String) {
        return value;
      }
    }

    final session = body['session'];
    if (session is Map<String, dynamic>) {
      final sessionClientSecret = session['client_secret'];
      if (sessionClientSecret is Map<String, dynamic>) {
        final value = sessionClientSecret['value'];
        if (value is String) {
          return value;
        }
      }
    }

    return null;
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
    required this.clientSecret,
    required this.callsUrl,
  });

  final String clientSecret;
  final String callsUrl;
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

  bool get hasCurrent =>
      currentOriginalText.isNotEmpty || currentTranslationText.isNotEmpty;

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

const _windows1252ByteByRune = <int, int>{
  0x20ac: 0x80,
  0x201a: 0x82,
  0x0192: 0x83,
  0x201e: 0x84,
  0x2026: 0x85,
  0x2020: 0x86,
  0x2021: 0x87,
  0x02c6: 0x88,
  0x2030: 0x89,
  0x0160: 0x8a,
  0x2039: 0x8b,
  0x0152: 0x8c,
  0x017d: 0x8e,
  0x2018: 0x91,
  0x2019: 0x92,
  0x201c: 0x93,
  0x201d: 0x94,
  0x2022: 0x95,
  0x2013: 0x96,
  0x2014: 0x97,
  0x02dc: 0x98,
  0x2122: 0x99,
  0x0161: 0x9a,
  0x203a: 0x9b,
  0x0153: 0x9c,
  0x017e: 0x9e,
  0x0178: 0x9f,
};
