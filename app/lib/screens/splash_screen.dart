import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/theme.dart';

/// Nome completo e lema da marca.
const appFullName = 'Bazá Tranquilo';
const appSlogan = 'Bazá com Segurança';

/// Ecrã de arranque: fundo amarelo, a seta do Bazá a "descolar" para o centro,
/// o nome completo e o lema. Com [error], mostra o problema e como o resolver
/// (por exemplo quando o servidor não responde).
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.error, this.onRetry, this.onLogout});
  final String? error;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onLogout;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..forward();
  late final _bar = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _intro.dispose();
    _bar.dispose();
    super.dispose();
  }

  /// Parte da animação de entrada entre [from] e [to] (0–1), suavizada.
  Animation<double> _part(
    double from,
    double to, [
    Curve curve = Curves.easeOut,
  ]) => CurvedAnimation(
    parent: _intro,
    curve: Interval(from, to, curve: curve),
  );

  @override
  Widget build(BuildContext context) {
    // Quem pediu menos movimento vê tudo já no lugar.
    final still = MediaQuery.disableAnimationsOf(context);
    if (still && _intro.value < 1) _intro.value = 1;
    final arrive = _part(0, .55, Curves.easeOutBack);
    final name = _part(.35, .75);
    final slogan = _part(.6, 1);
    final error = widget.error;

    return Scaffold(
      backgroundColor: BazaColors.yellow,
      body: SafeArea(
        child: Center(
          // Desloca-se quando não cabe (telemóvel deitado, com a mensagem de erro e
          // o botão), em vez de transbordar.
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // A seta entra de baixo-esquerda, na direcção em que aponta.
                AnimatedBuilder(
                  animation: arrive,
                  builder: (context, child) => Transform.translate(
                    offset: Offset(
                      -70 * (1 - arrive.value),
                      70 * (1 - arrive.value),
                    ),
                    child: Transform.scale(
                      scale: .5 + .5 * arrive.value,
                      child: Opacity(
                        opacity: arrive.value.clamp(0, 1),
                        child: child,
                      ),
                    ),
                  ),
                  child: SvgPicture.asset(
                    'assets/brand/arrow.svg',
                    width: 128,
                    height: 128,
                  ),
                ),
                FadeTransition(
                  opacity: name,
                  child: Semantics(
                    header: true,
                    label: appFullName,
                    child: const ExcludeSemantics(
                      child: Text.rich(
                        TextSpan(
                          text: 'Bazá ',
                          children: [
                            TextSpan(
                              text: 'Tranquilo',
                              style: TextStyle(fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 44,
                          height: 1,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1.5,
                          color: BazaColors.ink,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                FadeTransition(
                  opacity: slogan,
                  child: const Text(
                    appSlogan,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: BazaColors.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 34),
                if (error == null)
                  _LoadingBar(animation: _bar, still: still)
                else ...[
                  Text(
                    error,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: BazaColors.ink,
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: BazaColors.ink,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: widget.onRetry,
                    child: const Text('Tentar novamente'),
                  ),
                  TextButton(
                    onPressed: widget.onLogout,
                    child: const Text('Sair da conta'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Barra fina com um traço a correr, como uma estrada.
class _LoadingBar extends StatelessWidget {
  const _LoadingBar({required this.animation, required this.still});
  final Animation<double> animation;
  final bool still;

  @override
  Widget build(BuildContext context) {
    const width = 120.0, dash = 48.0;
    return Semantics(
      label: 'A carregar',
      child: Container(
        width: width,
        height: 4,
        decoration: BoxDecoration(
          color: BazaColors.ink.withValues(alpha: .18),
          borderRadius: BorderRadius.circular(4),
        ),
        clipBehavior: Clip.antiAlias,
        child: still
            ? const Align(
                child: SizedBox(
                  width: dash,
                  height: 4,
                  child: ColoredBox(color: BazaColors.ink),
                ),
              )
            : AnimatedBuilder(
                animation: animation,
                builder: (context, _) => Stack(
                  children: [
                    Positioned(
                      left: -dash + (width + dash) * animation.value,
                      child: Container(
                        width: dash,
                        height: 4,
                        decoration: BoxDecoration(
                          color: BazaColors.ink,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
