import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'common.dart';
import 'made_by.dart';

/// Versão para computador: em ecrãs largos, o app inteiro (ecrãs, janelas e
/// painéis inferiores) fica numa "janela" centrada com as medidas de um
/// telemóvel grande, sobre um fundo com a marca. Em ecrãs estreitos não faz
/// nada. Usa-se em `MaterialApp.builder`, para ficar por fora do navegador.
class DesktopFrame extends StatelessWidget {
  const DesktopFrame({super.key, required this.child});

  final Widget child;

  /// Largura do ecrã a partir da qual o app passa a aparecer numa janela.
  static const breakpoint = 900.0;

  /// A partir desta largura cabe também o painel da marca, à esquerda.
  static const brandBreakpoint = 1100.0;
  static const windowWidth = 460.0;
  static const windowMaxHeight = 920.0;

  static bool isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= breakpoint;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    if (screen.width < breakpoint) return child;
    final height = (screen.height - 48).clamp(0.0, windowMaxHeight);
    final window = Container(
      width: windowWidth,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 60,
            offset: const Offset(0, 24),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      // Os ecrãs medem-se pela janela, não pelo monitor.
      child: MediaQuery(
        data: media.copyWith(
          size: Size(windowWidth, height),
          padding: EdgeInsets.zero,
          viewPadding: EdgeInsets.zero,
        ),
        child: child,
      ),
    );
    return Stack(
      children: [
        const Positioned.fill(child: _Backdrop()),
        Center(
          child: screen.width < brandBreakpoint
              ? window
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 420, child: _BrandPanel()),
                    const SizedBox(width: 72),
                    window,
                  ],
                ),
        ),
      ],
    );
  }
}

/// Fundo escuro com um clarão amarelo e setas da marca muito ténues.
class _Backdrop extends StatelessWidget {
  const _Backdrop();

  @override
  Widget build(BuildContext context) {
    const marks = <(Alignment, double, double)>[
      (Alignment(-0.95, -0.85), 190, 0.0),
      (Alignment(-0.35, 0.95), 150, 0.4),
      (Alignment(0.95, -0.6), 170, -0.3),
      (Alignment(0.75, 0.9), 210, 0.2),
      (Alignment(0.1, -1.0), 120, 0.6),
    ];
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(-0.6, -0.5),
          radius: 1.4,
          colors: [Color(0xFF2B2A1F), Color(0xFF1A1C21), BazaColors.ink],
          stops: [0, 0.55, 1],
        ),
      ),
      child: ClipRect(
        child: Stack(
          children: [
            for (final (alignment, size, turn) in marks)
              Align(
                alignment: alignment,
                child: Transform.rotate(
                  angle: turn,
                  child: Icon(
                    Icons.near_me_rounded,
                    size: size,
                    color: BazaColors.yellow.withValues(alpha: 0.05),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Marca e três linhas sobre o serviço, ao lado da janela do app.
class _BrandPanel extends StatelessWidget {
  const _BrandPanel();

  @override
  Widget build(BuildContext context) {
    // Texto simples, fora do tema do app (aqui o fundo é escuro).
    return DefaultTextStyle(
      style: const TextStyle(
        color: Colors.white,
        fontSize: 16,
        height: 1.45,
        decoration: TextDecoration.none,
        fontWeight: FontWeight.w400,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const BazaLogo(size: 64, color: Colors.white),
          const SizedBox(height: 28),
          const Text(
            'Bazá com Segurança.',
            style: TextStyle(
              fontSize: 44,
              height: 1.08,
              fontWeight: FontWeight.w900,
              letterSpacing: -1.2,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Táxi, moto e carga em Angola. Peça uma corrida, acompanhe o motorista no mapa e chegue tranquilo.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.72)),
          ),
          const SizedBox(height: 28),
          const _BrandPoint(
            icon: Icons.shield_outlined,
            text: 'Motoristas com documentos verificados',
          ),
          const _BrandPoint(
            icon: Icons.share_location_outlined,
            text: 'Partilhe a viagem com quem confia',
          ),
          const _BrandPoint(
            icon: Icons.payments_outlined,
            text: 'Preço à vista antes de pedir',
          ),
          const SizedBox(height: 36),
          Text(
            madeBy,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _BrandPoint extends StatelessWidget {
  const _BrandPoint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: BazaColors.yellow.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 20, color: BazaColors.yellow),
          ),
          const SizedBox(width: 14),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
