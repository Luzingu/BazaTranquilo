import 'package:audioplayers/audioplayers.dart';

/// Avisos falados ao passageiro durante a corrida: um toque seguido de uma
/// frase gravada (ficheiros em assets/sounds/voz_*.wav). São gravações, e não
/// a voz sintética do telemóvel, para soarem igual em todos os aparelhos e
/// funcionarem sem rede.
class Voice {
  Voice._();
  static final instance = Voice._();

  /// Em testes automáticos não se toca nada.
  static bool enabled = true;

  static const accepted = 'voz_aceite'; // "O seu motorista aceitou a corrida…"
  static const arrived = 'voz_chegou'; // "O seu motorista já chegou…"
  static const started = 'voz_inicio'; // "Bem-vindo ao Bazá Tranquilo…"
  static const finished = 'voz_fim'; // "Chegou ao seu destino…"

  AudioPlayer? _player;

  /// Toca o aviso; um aviso novo interrompe o anterior. Falhas de som (ex.:
  /// browser que ainda bloqueia áudio) nunca afectam a corrida.
  void say(String name) {
    if (!enabled) return;
    try {
      final player = _player ??= AudioPlayer();
      player
          .stop()
          .then((_) => player.setReleaseMode(ReleaseMode.stop))
          .then((_) => player.play(AssetSource('sounds/$name.wav')))
          .catchError((_) {});
    } catch (_) {}
  }
}
