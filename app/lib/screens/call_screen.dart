import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../state/call_state.dart';
import '../widgets/common.dart';

/// Ecrã da chamada de voz: a tocar, a ligar, em conversa ou terminada.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Actualiza o tempo de conversa a cada segundo.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String _status(CallState call) {
    switch (call.phase) {
      case CallPhase.outgoing:
        return 'A chamar…';
      case CallPhase.incoming:
        return 'Chamada do Bazá';
      case CallPhase.connecting:
        return 'A ligar…';
      case CallPhase.active:
        final s = DateTime.now()
            .difference(call.connectedAt ?? DateTime.now())
            .inSeconds;
        return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
      case CallPhase.ended:
      case CallPhase.idle:
        return call.endReason ?? 'Chamada terminada.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final call = context.watch<CallState>();
    final peer = call.peer;
    final iAmDriver = call.session.user?.isDriver ?? false;
    final name = (peer?.name ?? '').isEmpty
        ? (iAmDriver ? 'Passageiro' : 'Motorista')
        : peer!.name;
    final vehicle = peer?.vehicle;
    final over = call.phase == CallPhase.ended || call.phase == CallPhase.idle;

    return PopScope(
      // Sair do ecrã não desliga por acidente: usa-se o botão vermelho.
      canPop: over,
      child: Scaffold(
        backgroundColor: BazaColors.ink,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
                    child: Column(
                      children: [
                        // Na web, é este elemento (invisível) que reproduz o áudio remoto.
                        if (kIsWeb && !over)
                          SizedBox(
                            width: 1,
                            height: 1,
                            child: RTCVideoView(call.remoteRenderer),
                          ),
                        const Text(
                          'Chamada pelo app · o seu número não é mostrado',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white60, fontSize: 13),
                        ),
                        const Spacer(),
                        Avatar(
                          name: name,
                          photoUrl: peer?.photoUrl,
                          radius: 58,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          name,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          iAmDriver
                              ? 'Passageiro'
                              : (vehicle == null
                                    ? 'Motorista'
                                    : 'Motorista · ${vehicle.plate}'),
                          style: const TextStyle(color: Colors.white60),
                        ),
                        const SizedBox(height: 22),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            _status(call),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: call.phase == CallPhase.active
                                  ? BazaColors.yellow
                                  : Colors.white,
                              fontSize: call.phase == CallPhase.active
                                  ? 30
                                  : 18,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        const Spacer(flex: 2),
                        if (call.phase == CallPhase.incoming)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _RoundButton(
                                icon: Icons.call_end,
                                label: 'Recusar',
                                color: BazaColors.red,
                                onTap: call.reject,
                              ),
                              _RoundButton(
                                icon: Icons.call,
                                label: 'Atender',
                                color: BazaColors.green,
                                onTap: call.accept,
                              ),
                            ],
                          )
                        else if (!over)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _RoundButton(
                                icon: call.muted ? Icons.mic_off : Icons.mic,
                                label: call.muted
                                    ? 'Microfone desligado'
                                    : 'Silenciar',
                                color: call.muted
                                    ? Colors.white
                                    : Colors.white24,
                                foreground: call.muted
                                    ? BazaColors.ink
                                    : Colors.white,
                                size: 60,
                                onTap: call.toggleMute,
                              ),
                              _RoundButton(
                                icon: Icons.call_end,
                                label: 'Desligar',
                                color: BazaColors.red,
                                onTap: call.hangUp,
                              ),
                              if (!kIsWeb)
                                _RoundButton(
                                  icon: call.speaker
                                      ? Icons.volume_up
                                      : Icons.volume_up_outlined,
                                  label: call.speaker
                                      ? 'Alta-voz ligada'
                                      : 'Alta-voz',
                                  color: call.speaker
                                      ? Colors.white
                                      : Colors.white24,
                                  foreground: call.speaker
                                      ? BazaColors.ink
                                      : Colors.white,
                                  size: 60,
                                  onTap: call.toggleSpeaker,
                                )
                              else
                                const SizedBox(width: 60),
                            ],
                          )
                        else
                          const SizedBox(height: 96),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.foreground = Colors.white,
    this.size = 72,
  });
  final IconData icon;
  final String label;
  final Color color, foreground;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: ExcludeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: color,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: size,
                height: size,
                child: Icon(icon, color: foreground, size: size * .45),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            // Estreito o suficiente para três botões caberem num ecrã pequeno.
            width: 84,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );
}
