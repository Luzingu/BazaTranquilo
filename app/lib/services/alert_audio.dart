import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import '../core/api.dart';

/// Som da viagem durante um alerta de perigo. Quem accionou o alerta pode
/// partilhar o que se ouve na viatura com os agentes que acompanham o caso.
///
/// O microfone é lido em contínuo e enviado em blocos de poucos segundos (WAV,
/// voz em mono a 8 kHz, para gastar poucos dados). Continua mesmo depois de se
/// fechar o painel do SOS e pára quando o alerta é fechado ou cancelado.
class AlertAudio extends ChangeNotifier {
  AlertAudio._();
  static final instance = AlertAudio._();

  static const _inputRate = 16000;
  static const _chunkSeconds = 8;
  static const _chunkBytes = _inputRate * 2 * _chunkSeconds;

  // No Android, um serviço em primeiro plano (com notificação permanente)
  // mantém o microfone e o envio a funcionar com o ecrã bloqueado ou com outra
  // aplicação aberta. Ver android/.../AlertAudioService.kt.
  static const _service = MethodChannel('ao.baza.baza/som_da_viagem');
  static bool get _hasService =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Falso quando o serviço não arrancou: aí só se grava com o app no ecrã.
  bool background = false;

  Future<void> _setService(bool on) async {
    if (!_hasService) return;
    try {
      final ok = await _service.invokeMethod<bool>(on ? 'start' : 'stop');
      background = on && ok == true;
    } catch (_) {
      background = false;
    }
  }

  /// A corrida cujo som está a ser partilhado, ou null.
  String? rideId;

  /// Blocos já entregues ao servidor.
  int sent = 0;

  /// Mensagem a mostrar quando a partilha falha ou pára sozinha.
  String? problem;

  bool get sharing => rideId != null;

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _sub;
  ApiClient? _api;
  BytesBuilder _buffer = BytesBuilder(copy: false);
  Future<void> _uploads = Future.value();

  Future<void> start(ApiClient api, String ride) async {
    if (sharing) return;
    problem = null;
    final recorder = AudioRecorder();
    try {
      if (!await recorder.hasPermission()) {
        throw 'Sem acesso ao microfone. Autorize o microfone para o Bazá nas definições do telemóvel.';
      }
      // Primeiro o serviço (tem de arrancar com o app no ecrã), depois o microfone.
      await _setService(true);
      final stream = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _inputRate,
          numChannels: 1,
          noiseSuppress: true,
          autoGain: true,
        ),
      );
      _recorder = recorder;
      _api = api;
      rideId = ride;
      sent = 0;
      _buffer = BytesBuilder(copy: false);
      _sub = stream.listen(_onData, onError: (_) => _fail());
      notifyListeners();
    } catch (e) {
      await _setService(false);
      await recorder.dispose();
      problem = e is String ? e : 'Não foi possível usar o microfone.';
      notifyListeners();
    }
  }

  void _onData(Uint8List data) {
    _buffer.add(data);
    if (_buffer.length >= _chunkBytes) _flush();
  }

  /// Fecha o bloco actual e põe-no na fila de envio (os blocos seguem por ordem).
  void _flush() {
    final pcm = _buffer.takeBytes();
    final ride = rideId;
    final api = _api;
    if (pcm.length < 2000 || ride == null || api == null) return;
    final wav = _wav8k(pcm);
    _uploads = _uploads.then((_) async {
      if (rideId != ride) return;
      try {
        await api.putBytes('/rides/$ride/sos/audio', wav, 'audio/wav');
        sent++;
        notifyListeners();
      } on ApiException catch (e) {
        // 409: o alerta foi fechado ou cancelado — já não há a quem enviar.
        if (e.status == 409) await stop();
      } catch (_) {
        // Falha de rede: este bloco perde-se; os seguintes continuam.
      }
    });
  }

  void _fail() {
    problem = 'A gravação foi interrompida.';
    stop();
  }

  Future<void> stop() async {
    if (!sharing) return;
    if (_buffer.length > 0) _flush();
    rideId = null;
    await _sub?.cancel();
    _sub = null;
    try {
      await _recorder?.stop();
      await _recorder?.dispose();
    } catch (_) {}
    _recorder = null;
    await _setService(false);
    notifyListeners();
  }

  /// PCM de 16 bits a 16 kHz → ficheiro WAV a 8 kHz (média de cada par de amostras).
  static Uint8List _wav8k(Uint8List pcm) {
    final input = ByteData.sublistView(pcm);
    final samples = pcm.length ~/ 4;
    final out = ByteData(44 + samples * 2);
    void text(int at, String s) {
      for (var i = 0; i < s.length; i++) {
        out.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    const rate = 8000;
    text(0, 'RIFF');
    out.setUint32(4, 36 + samples * 2, Endian.little);
    text(8, 'WAVEfmt ');
    out.setUint32(16, 16, Endian.little);
    out.setUint16(20, 1, Endian.little); // PCM
    out.setUint16(22, 1, Endian.little); // mono
    out.setUint32(24, rate, Endian.little);
    out.setUint32(28, rate * 2, Endian.little);
    out.setUint16(32, 2, Endian.little);
    out.setUint16(34, 16, Endian.little);
    text(36, 'data');
    out.setUint32(40, samples * 2, Endian.little);
    for (var i = 0; i < samples; i++) {
      final a = input.getInt16(i * 4, Endian.little);
      final b = input.getInt16(i * 4 + 2, Endian.little);
      out.setInt16(44 + i * 2, (a + b) >> 1, Endian.little);
    }
    return out.buffer.asUint8List();
  }
}
