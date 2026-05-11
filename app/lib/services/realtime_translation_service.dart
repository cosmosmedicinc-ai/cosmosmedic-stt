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
typedef CaptionChanged = void Function(CaptionState captions);
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
  CaptionState _captions = const CaptionState();

  Future<void> start({
    required LanguagePair languagePair,
    required StatusChanged onStatusChanged,
    required CaptionChanged onCaptionChanged,
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
        'Realtime start: language ${languagePair.sourceLanguage}->${languagePair.targetLanguage}',
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
          onCaptionChanged: onCaptionChanged,
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

    _captions = const CaptionState();
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

  Future<SessionConnectionData> _createSession(LanguagePair languagePair) async {
    final response = await _httpClient.post(
      Uri.parse('${AppConfig.serverUrl}/session'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'sourceLanguage': languagePair.sourceLanguage,
        'targetLanguage': languagePair.targetLanguage,
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
        'https://api.openai.com/v1/realtime/translations/calls';

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
    required CaptionChanged onCaptionChanged,
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
        _appendOriginalCaption(_readTextDelta(event));
        onCaptionChanged(_captions);
        break;
      case 'response.output_audio_transcript.delta':
      case 'response.output_text.delta':
      case 'session.output_transcript.delta':
        _appendTranslatedCaption(_readTextDelta(event));
        onCaptionChanged(_captions);
        break;
      case 'conversation.item.input_audio_transcription.completed':
      case 'session.input_transcript.completed':
      case 'session.input_transcript.done':
      case 'session.input_transcript.final':
        _finalizeOriginalCaption(_readTranscriptText(event));
        onCaptionChanged(_captions);
        break;
      case 'response.output_audio_transcript.done':
      case 'response.output_text.done':
      case 'session.output_transcript.completed':
      case 'session.output_transcript.done':
      case 'session.output_transcript.final':
        _finalizeTranslatedCaption(_readTranscriptText(event));
        onCaptionChanged(_captions);
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

  void _appendOriginalCaption(String delta) {
    if (delta.isEmpty) {
      return;
    }

    final base = _captions.originalIsFinal ? '' : _captions.originalText;
    _captions = _captions.copyWith(
      originalText: base + delta,
      originalIsFinal: false,
    );
  }

  void _appendTranslatedCaption(String delta) {
    if (delta.isEmpty) {
      return;
    }

    final base = _captions.translatedIsFinal ? '' : _captions.translatedText;
    _captions = _captions.copyWith(
      translatedText: base + delta,
      translatedIsFinal: false,
    );
  }

  void _finalizeOriginalCaption(String transcript) {
    _captions = _captions.copyWith(
      originalText: transcript.isEmpty ? _captions.originalText : transcript,
      originalIsFinal: true,
    );
  }

  void _finalizeTranslatedCaption(String transcript) {
    _captions = _captions.copyWith(
      translatedText:
          transcript.isEmpty ? _captions.translatedText : transcript,
      translatedIsFinal: true,
    );
  }

  String _readTextDelta(Map<String, dynamic> event) {
    final delta = event['delta'];
    if (delta is String) {
      return delta;
    }

    final text = event['text'];
    if (text is String) {
      return text;
    }

    return '';
  }

  String _readTranscriptText(Map<String, dynamic> event) {
    final transcript = event['transcript'];
    if (transcript is String) {
      return transcript;
    }

    final text = event['text'];
    if (text is String) {
      return text;
    }

    final delta = event['delta'];
    if (delta is String) {
      return delta;
    }

    return '';
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

class CaptionState {
  const CaptionState({
    this.originalText = '',
    this.translatedText = '',
    this.originalIsFinal = false,
    this.translatedIsFinal = false,
  });

  final String originalText;
  final String translatedText;
  final bool originalIsFinal;
  final bool translatedIsFinal;

  CaptionState copyWith({
    String? originalText,
    String? translatedText,
    bool? originalIsFinal,
    bool? translatedIsFinal,
  }) {
    return CaptionState(
      originalText: originalText ?? this.originalText,
      translatedText: translatedText ?? this.translatedText,
      originalIsFinal: originalIsFinal ?? this.originalIsFinal,
      translatedIsFinal: translatedIsFinal ?? this.translatedIsFinal,
    );
  }
}

class RealtimeTranslationException implements Exception {
  const RealtimeTranslationException(this.message);

  final String message;
}
