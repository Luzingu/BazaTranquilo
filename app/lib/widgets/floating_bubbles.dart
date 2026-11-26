import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Bolinhas de luz que sobem devagar e se espalham pelo ecrã — o fundo do ecrã de arranque (pedido do dono,
/// 2026-11-26: «gostei dos efeitos das bolinhas … implementar também na tela inicial do Bazá»). É o mesmo efeito
/// do ecrã de abertura da app AngoSchool, copiado e adaptado às cores do Bazá (os produtos não partilham código).
///
/// Ficam por trás de tudo e não recebem toques. Com «reduzir animações» ligado no aparelho ([still]) ficam paradas.
class FloatingBubbles extends StatefulWidget {
  const FloatingBubbles({super.key, this.still = false});

  final bool still;

  @override
  State<FloatingBubbles> createState() => _FloatingBubblesState();
}

class _FloatingBubblesState extends State<FloatingBubbles>
    with TickerProviderStateMixin {
  late final _cycle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  // aparecem devagar, em vez de surgirem de repente
  late final _fadeIn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  @override
  void initState() {
    super.initState();
    if (!widget.still) _cycle.repeat();
  }

  @override
  void didUpdateWidget(FloatingBubbles old) {
    super.didUpdateWidget(old);
    if (widget.still) {
      _cycle.stop();
    } else if (!_cycle.isAnimating) {
      _cycle.repeat();
    }
  }

  @override
  void dispose() {
    _cycle.dispose();
    _fadeIn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: AnimatedBuilder(
        animation: Listenable.merge([_cycle, _fadeIn]),
        builder: (context, _) => CustomPaint(
          size: Size.infinite,
          painter: _BubblesPainter(
            _cycle.value,
            widget.still ? 1 : _fadeIn.value,
          ),
        ),
      ),
    ),
  );
}

class _BubblesPainter extends CustomPainter {
  _BubblesPainter(this.c, this.fade);

  final double c, fade;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.Random(7); // a mesma disposição em cada desenho
    for (var i = 0; i < 16; i++) {
      final x = r.nextDouble() * size.width;
      // sobe 1,2 alturas por ciclo (= o módulo): o fim do ciclo encaixa no início, sem salto
      final y = size.height * (1.1 - ((r.nextDouble() * 1.2 + c * 1.2) % 1.2));
      final radius = 3 + r.nextDouble() * 16;
      final light = r.nextDouble();
      // quase todas brancas sobre o amarelo; uma em cada quatro, um toque escuro e discreto
      final color = i % 4 == 0
          ? BazaColors.ink.withValues(alpha: (0.05 + 0.05 * light) * fade)
          : Colors.white.withValues(alpha: (0.18 + 0.22 * light) * fade);
      canvas.drawCircle(Offset(x, y), radius, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_BubblesPainter old) => old.c != c || old.fade != fade;
}
