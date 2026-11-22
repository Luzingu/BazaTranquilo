import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/models.dart';
import '../services/notifier.dart';
import 'ride_state.dart';
import 'session.dart';

enum CallPhase {
  idle,

  /// Liguei e estou à espera de que atendam.
  outgoing,

  /// Estão a ligar-me.
  incoming,

  /// Atendida; a estabelecer o áudio.
  connecting,

  /// A falar.
  active,

  /// Terminou; fica um instante no ecrã com o motivo.
  ended,
}

/// Chamadas de voz dentro do app entre o passageiro e o motorista de uma
/// corrida. O áudio vai directamente de um telemóvel ao outro (WebRTC); o
/// servidor só encaminha a sinalização pelo mesmo canal do chat.
class CallState extends ChangeNotifier {
  CallState(this.session, this.rides) {
    session.on('call:signal', _onSignal);
  }

  final Session session;
  final RideState rides;

  CallPhase phase = CallPhase.idle;
  Ride? ride;
  RideParty? peer;

  /// Porque terminou (mostrado no ecrã), ex.: "Chamada recusada".
  String? endReason;
  bool muted = false;
  bool speaker = false;
  DateTime? connectedAt;

  /// Reproduz o áudio remoto (na web é isto que cria o elemento de áudio).
  final remoteRenderer = RTCVideoRenderer();
  bool _rendererReady = false;

  RTCPeerConnection? _pc;
  MediaStream? _local;
  final _pendingCandidates = <Map<String, dynamic>>[];
  bool _remoteSet = false;
  Timer? _timeout;
  Timer? _buzz;
  Timer? _clear;
  AudioPlayer? _tone;
  bool _disposed = false;

  bool get busy => phase != CallPhase.idle && phase != CallPhase.ended;

  // ── Acções do utilizador ──────────────────────────────────────────────────

  /// Liga à outra pessoa da corrida.
  Future<void> call(Ride forRide) async {
    final other = (session.user?.isDriver ?? false)
        ? forRide.passenger
        : forRide.driver;
    if (busy || other == null) return;
    _reset();
    ride = forRide;
    peer = other;
    phase = CallPhase.outgoing;
    _notify();
    _playTone('ringback');
    _send('invite');
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 40), () {
      _send('hangup');
      _end('Sem resposta.');
    });
  }

  /// Atende a chamada recebida.
  Future<void> accept() async {
    if (phase != CallPhase.incoming) return;
    // Pára o temporizador de "chamada perdida": sem isto, a chamada já atendida
    // era cortada 45 segundos depois de ter começado a tocar.
    _timeout?.cancel();
    _stopAlerts();
    phase = CallPhase.connecting;
    _notify();
    try {
      await _preparePeer();
      _send('accept');
      _timeout?.cancel();
      _timeout = Timer(const Duration(seconds: 25), () => _fail());
    } catch (_) {
      _send('reject');
      _end('Não foi possível usar o microfone. Verifique a permissão do app.');
    }
  }

  void reject() {
    if (phase != CallPhase.incoming) return;
    _send('reject');
    _end(null);
  }

  void hangUp() {
    if (!busy) return;
    _send('hangup');
    _end('Chamada terminada.');
  }

  void toggleMute() {
    muted = !muted;
    for (final track
        in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
    _notify();
  }

  /// Alta-voz (só nos telemóveis; no browser é o sistema que escolhe a saída).
  void toggleSpeaker() {
    speaker = !speaker;
    if (!kIsWeb) Helper.setSpeakerphoneOn(speaker).catchError((_) {});
    _notify();
  }

  // ── Sinalização ───────────────────────────────────────────────────────────

  void _send(String type, [Map<String, dynamic>? data]) {
    final id = ride?.id;
    if (id != null)
      session.emit('call:signal', {'rideId': id, 'type': type, 'data': ?data});
  }

  void _onSignal(dynamic payload) {
    if (payload is! Map || _disposed) return;
    final type = payload['type'] as String?;
    final rideId = payload['rideId'] as String?;
    final data = payload['data'] is Map
        ? Map<String, dynamic>.from(payload['data'] as Map)
        : const <String, dynamic>{};

    if (type == 'invite') {
      final current = rides.ride;
      if (current == null || current.id != rideId) return;
      if (busy) {
        // Já estou numa chamada (ou a ligar ao mesmo tempo): a outra pessoa é avisada.
        session.emit('call:signal', {'rideId': rideId, 'type': 'busy'});
        return;
      }
      _reset();
      ride = current;
      peer = (session.user?.isDriver ?? false)
          ? current.passenger
          : current.driver;
      phase = CallPhase.incoming;
      Notifier.instance.show(
        Notifier.callId,
        'Chamada do Bazá',
        '${peer?.name ?? 'O outro interveniente'} está a ligar-lhe.',
        urgent: true,
      );
      _notify();
      _playTone('ring');
      HapticFeedback.heavyImpact();
      _buzz = Timer.periodic(
        const Duration(seconds: 2),
        (_) => HapticFeedback.heavyImpact(),
      );
      _send('ringing');
      _timeout?.cancel();
      _timeout = Timer(
        const Duration(seconds: 45),
        () => _end('Chamada perdida.'),
      );
      return;
    }
    if (rideId != ride?.id || !busy) return;

    switch (type) {
      case 'accept':
        if (phase == CallPhase.outgoing) _startAsCaller();
      case 'offer':
        _answerOffer(data);
      case 'answer':
        _applyAnswer(data);
      case 'candidate':
        _addCandidate(data);
      case 'reject':
        _end('Chamada recusada.');
      case 'busy':
        _end('A outra pessoa está noutra chamada.');
      case 'unavailable':
        _end(
          'A outra pessoa não tem o app aberto. Experimente ligar pelo telefone.',
        );
      case 'hangup':
        _end('Chamada terminada.');
    }
  }

  Future<void> _startAsCaller() async {
    _timeout?.cancel();
    _stopAlerts();
    phase = CallPhase.connecting;
    _notify();
    try {
      await _preparePeer();
      final offer = await _pc!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });
      await _pc!.setLocalDescription(offer);
      _send('offer', {'sdp': offer.sdp, 'type': offer.type});
      _timeout?.cancel();
      _timeout = Timer(const Duration(seconds: 25), () => _fail());
    } catch (_) {
      _send('hangup');
      _end('Não foi possível usar o microfone. Verifique a permissão do app.');
    }
  }

  Future<void> _answerOffer(Map<String, dynamic> data) async {
    final pc = _pc;
    if (pc == null || phase != CallPhase.connecting) return;
    try {
      await pc.setRemoteDescription(
        RTCSessionDescription(data['sdp'] as String?, data['type'] as String?),
      );
      await _flushCandidates();
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      _send('answer', {'sdp': answer.sdp, 'type': answer.type});
    } catch (_) {
      _fail();
    }
  }

  Future<void> _applyAnswer(Map<String, dynamic> data) async {
    final pc = _pc;
    if (pc == null) return;
    try {
      await pc.setRemoteDescription(
        RTCSessionDescription(data['sdp'] as String?, data['type'] as String?),
      );
      await _flushCandidates();
    } catch (_) {
      _fail();
    }
  }

  void _addCandidate(Map<String, dynamic> data) {
    // Os candidatos podem chegar antes da descrição remota: ficam em espera.
    if (_pc == null || !_remoteSet) {
      _pendingCandidates.add(data);
    } else {
      _applyCandidate(data);
    }
  }

  Future<void> _applyCandidate(Map<String, dynamic> data) async {
    final candidate = data['candidate'] as String?;
    if (candidate == null || candidate.isEmpty)
      return; // fim da lista de candidatos
    try {
      await _pc?.addCandidate(
        RTCIceCandidate(
          candidate,
          data['sdpMid'] as String? ?? '0',
          (data['sdpMLineIndex'] as num?)?.toInt() ?? 0,
        ),
      );
    } catch (_) {
      // Um candidato que não serve não deve deitar a chamada abaixo.
    }
  }

  Future<void> _flushCandidates() async {
    _remoteSet = true;
    final waiting = List<Map<String, dynamic>>.of(_pendingCandidates);
    _pendingCandidates.clear();
    for (final data in waiting) {
      await _applyCandidate(data);
    }
  }

  // ── Ligação de áudio ──────────────────────────────────────────────────────

  Future<void> _preparePeer() async {
    final res = await session.api.get('/rides/${ride!.id}/call-config');
    if (!_rendererReady) {
      await remoteRenderer.initialize();
      _rendererReady = true;
    }
    // Pede o microfone (o sistema mostra o pedido de permissão na primeira vez).
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    final pc = await createPeerConnection({
      'iceServers': res['iceServers'],
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;
    for (final track in _local!.getAudioTracks()) {
      await pc.addTrack(track, _local!);
    }
    pc.onIceCandidate = (c) {
      if (c.candidate != null && c.candidate!.isNotEmpty) {
        _send('candidate', {
          'candidate': c.candidate,
          'sdpMid': c.sdpMid,
          'sdpMLineIndex': c.sdpMLineIndex,
        });
      }
    };
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty)
        remoteRenderer.srcObject = event.streams.first;
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
          phase == CallPhase.connecting) {
        _timeout?.cancel();
        phase = CallPhase.active;
        connectedAt = DateTime.now();
        HapticFeedback.mediumImpact();
        _notify();
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _fail();
      }
    };
    // Começa no auscultador, como uma chamada normal.
    if (!kIsWeb) await Helper.setSpeakerphoneOn(false).catchError((_) {});
  }

  /// O áudio não chegou a ligar (rede que bloqueia a ligação directa).
  void _fail() {
    if (!busy) return;
    _send('hangup');
    _end(
      'Não foi possível estabelecer a chamada nesta rede. Experimente ligar pelo telefone.',
    );
  }

  // ── Fim e limpeza ─────────────────────────────────────────────────────────

  void _playTone(String name) {
    try {
      final player = _tone ??= AudioPlayer();
      player
          .setReleaseMode(ReleaseMode.loop)
          .then((_) => player.play(AssetSource('sounds/$name.wav')))
          .catchError((_) {});
    } catch (_) {}
  }

  void _stopAlerts() {
    _buzz?.cancel();
    _buzz = null;
    _tone?.stop().catchError((_) {});
  }

  void _releaseMedia() {
    _timeout?.cancel();
    _timeout = null;
    _stopAlerts();
    for (final track in _local?.getTracks() ?? const <MediaStreamTrack>[]) {
      track.stop().catchError((_) {});
    }
    _local?.dispose().catchError((_) {});
    _local = null;
    _pc?.close().catchError((_) {});
    _pc = null;
    if (_rendererReady) remoteRenderer.srcObject = null;
    _pendingCandidates.clear();
    _remoteSet = false;
  }

  void _reset() {
    _clear?.cancel();
    _releaseMedia();
    endReason = null;
    muted = false;
    speaker = false;
    connectedAt = null;
  }

  /// Termina a chamada. Com [reason], o ecrã mostra-o um instante antes de fechar.
  void _end(String? reason) {
    if (phase == CallPhase.idle) return;
    _releaseMedia();
    _clear?.cancel();
    if (reason == null) {
      phase = CallPhase.idle;
      ride = null;
      peer = null;
    } else {
      phase = CallPhase.ended;
      endReason = reason;
      _clear = Timer(const Duration(milliseconds: 2200), () {
        phase = CallPhase.idle;
        ride = null;
        peer = null;
        _notify();
      });
    }
    _notify();
  }

  /// Só para testes: põe a chamada num estado sem tocar no microfone.
  @visibleForTesting
  void debugSet(
    CallPhase next, {
    Ride? forRide,
    RideParty? withPeer,
    String? reason,
  }) {
    phase = next;
    ride = forRide ?? ride;
    peer = withPeer ?? peer;
    endReason = reason;
    if (next == CallPhase.active) connectedAt = DateTime.now();
    _notify();
  }

  void _notify() {
    session.inCall = phase != CallPhase.idle;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (busy) _send('hangup');
    _disposed = true;
    _clear?.cancel();
    _releaseMedia();
    _tone?.dispose();
    if (_rendererReady) remoteRenderer.dispose();
    session.off('call:signal', _onSignal);
    super.dispose();
  }
}
