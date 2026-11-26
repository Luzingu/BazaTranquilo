import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Quem fez o app: aparece, discreto, em todas as telas.
const madeBy = 'Criado por Luzingu Tech';

/// Selo de autoria por cima de todas as telas (ligado em `MaterialApp.builder`,
/// por isso apanha também as telas futuras). Pequeno, num balão translúcido no
/// canto de baixo, para se ler em fundo claro, escuro ou no mapa. Não recebe
/// toques (nunca tapa um botão) e esconde-se com o teclado aberto.
class MadeBySeal extends StatelessWidget {
  const MadeBySeal({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboardOpen = media.viewInsets.bottom > 0;
    return Stack(
      children: [
        child,
        if (!keyboardOpen)
          Positioned(
            right: 8,
            bottom: media.viewPadding.bottom + 4,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    madeBy,
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                      color: BazaColors.muted,
                      decoration: TextDecoration.none,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
