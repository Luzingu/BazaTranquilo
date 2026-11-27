import 'package:flutter/material.dart';

import '../core/servidores.dart';
import '../core/theme.dart';

/// ⛔ Só ícones que JÁ existiam na versão 1.0.0+2 publicada: as correcções Shorebird não mudam a fonte dos ícones (a da
/// loja foi compilada só com os usados) — um ícone novo apareceria como um quadrado vazio.
///
/// Parte visível da escolha de servidor (2026-11-27, `core/servidores.dart`) — copiada e adaptada da app AngoSchool.
///  • [instalarEscolhaDeServidor]: a PERGUNTA antes de passar ao servidor sem saldo (no `main()`, com a chave do navegador).
///  • [FaixaServidor]: faixa «Modo sem saldo» no topo de todas as telas (no `builder` do `MaterialApp`).
///  • [abrirEscolhaServidor]: o modo (Automático · Só o principal · Sempre sem saldo) e «Mudar sem perguntar» — menu
///    lateral › «Ligação ao servidor» e o botão «Mudar» da faixa.

/// Instala a pergunta. Sem navegador montado, muda sem perguntar (é melhor do que ficar sem ligação).
void instalarEscolhaDeServidor(GlobalKey<NavigatorState> navegador) {
  Servidores.aoPedirAutorizacao = (de, para) async {
    final ctx = navegador.currentContext;
    if (ctx == null) return true;
    final sim = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.cloud_off, color: BazaColors.ink, size: 36),
        title: const Text('Continuar sem saldo de dados?'),
        content: const Text(
          'Não conseguimos chegar ao servidor principal. Pode continuar pelo servidor sem custo de dados '
          '(angoschool.org) — funciona tudo, incluindo as chamadas.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Tentar de novo')),
          FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('Continuar sem saldo')),
        ],
      ),
    );
    return sim ?? false;
  };
}

/// Faixa amarela-escura «Modo sem saldo» por cima de tudo, só quando o servidor em uso é o sem saldo.
class FaixaServidor extends StatelessWidget {
  const FaixaServidor({super.key, required this.child, required this.navegador});
  final Widget child;
  final GlobalKey<NavigatorState> navegador;

  @override
  Widget build(BuildContext context) {
    if (!Servidores.activa) return child;
    return ValueListenableBuilder<Servidor>(
      valueListenable: Servidores.activo,
      builder: (context, s, _) {
        if (!s.semSaldo) return child;
        return Column(
          children: [
            Material(
              color: const Color(0xFF3A3000),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                  child: Row(
                    children: [
                      const Icon(Icons.payments_outlined, color: BazaColors.yellow, size: 20),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Modo sem saldo · sem custo de dados',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          final ctx = navegador.currentContext;
                          if (ctx != null) abrirEscolhaServidor(ctx);
                        },
                        child: const Text('Mudar', style: TextStyle(color: BazaColors.yellow, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(child: MediaQuery.removePadding(context: context, removeTop: true, child: child)),
          ],
        );
      },
    );
  }
}

const _modos = <ModoServidor, (String, String, IconData)>{
  ModoServidor.automatico: ('Automático', 'O principal; sem ligação a ele, o servidor sem saldo.', Icons.refresh),
  ModoServidor.principal: ('Só o principal', 'Usa sempre bazatranquilo.com (gasta saldo de dados).', Icons.check_circle_outline),
  ModoServidor.semSaldo: ('Sempre sem saldo', 'Usa sempre angoschool.org — não gasta saldo de dados.', Icons.payments_outlined),
};

/// Folha com o modo da ligação. Só fecha pelo botão ou pela pega (regra do app: nada fecha ao tocar fora).
Future<void> abrirEscolhaServidor(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isDismissible: false,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => const _FolhaServidor(),
);

class _FolhaServidor extends StatefulWidget {
  const _FolhaServidor();
  @override
  State<_FolhaServidor> createState() => _FolhaServidorState();
}

class _FolhaServidorState extends State<_FolhaServidor> {
  bool _aMudar = false;

  Future<void> _escolher(ModoServidor m) async {
    if (_aMudar || m == Servidores.modo) return;
    setState(() => _aMudar = true);
    await Servidores.definirModo(m);
    if (mounted) setState(() => _aMudar = false);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: ValueListenableBuilder<Servidor>(
          valueListenable: Servidores.activo,
          builder: (context, activo, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('Ligação ao servidor', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  ),
                  IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close), tooltip: 'Fechar'),
                ],
              ),
              Row(
                children: [
                  Icon(activo.semSaldo ? Icons.payments_outlined : Icons.check_circle, size: 18, color: BazaColors.muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Ligado agora a ${Uri.parse(activo.base).host}${activo.semSaldo ? ' (sem saldo)' : ' (principal)'}',
                      style: const TextStyle(color: BazaColors.muted),
                    ),
                  ),
                  if (_aMudar) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ),
              const SizedBox(height: 8),
              for (final e in _modos.entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(e.value.$3, color: BazaColors.ink, size: 28),
                  title: Text(e.value.$1, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(e.value.$2),
                  trailing: Icon(
                    Servidores.modo == e.key ? Icons.check_circle : Icons.circle,
                    color: Servidores.modo == e.key ? BazaColors.ink : BazaColors.muted,
                  ),
                  onTap: () => _escolher(e.key),
                ),
              if (Servidores.modo == ModoServidor.automatico)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Mudar sem perguntar'),
                  subtitle: const Text('Sem ligação ao principal, passa logo ao servidor sem saldo.'),
                  value: Servidores.autorizadoSemPerguntar,
                  onChanged: (v) async {
                    await Servidores.definirAutorizacao(v);
                    if (mounted) setState(() {});
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
