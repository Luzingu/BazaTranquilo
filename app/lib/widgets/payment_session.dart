import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/theme.dart';

/// Abre a sessão de pagamento que o servidor devolveu (ex.: uma referência para
/// carregar o saldo). Devolve true se ficar paga enquanto está aberta.
Future<bool> showPaymentSession(
  BuildContext context,
  ApiClient api,
  Map<String, dynamic> payment,
) async {
  final paid = await showModalBottomSheet<bool>(
    context: context,
    isDismissible: false,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Colors.white,
    builder: (_) => PaymentSessionSheet(api: api, initial: payment),
  );
  return paid == true;
}

/// Ecrã de pagamento genérico: o app não sabe como cada fornecedor funciona.
/// Mostra o que o servidor manda — título, forma de pagamento, valor, estado,
/// mensagem, dados para copiar (entidade, referência…) e um link opcional — e
/// pergunta o estado de [pollSeconds] em [pollSeconds] segundos até terminar.
/// Mudar de fornecedor ou de forma de pagamento faz-se só no servidor.
class PaymentSessionSheet extends StatefulWidget {
  const PaymentSessionSheet({
    super.key,
    required this.api,
    required this.initial,
  });
  final ApiClient api;
  final Map<String, dynamic> initial;

  @override
  State<PaymentSessionSheet> createState() => _PaymentSessionSheetState();
}

class _PaymentSessionSheetState extends State<PaymentSessionSheet> {
  late Map<String, dynamic> _p = widget.initial;
  Timer? _timer;

  String get _status => _p['status'] as String? ?? 'pending';
  bool get _done => _status != 'pending' && _status != 'awaiting_input';

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    final seconds = (_p['pollSeconds'] as num? ?? 0).round();
    if (_done || seconds <= 0) return;
    _timer = Timer(Duration(seconds: seconds), _refresh);
  }

  Future<void> _refresh() async {
    try {
      final res = await widget.api.get('/payments/${_p['id']}');
      if (!mounted) return;
      setState(() => _p = Map<String, dynamic>.from(res['payment'] as Map));
      if (_status == 'paid') HapticFeedback.mediumImpact();
    } on ApiException {
      // Sem rede: tenta outra vez na próxima volta.
    }
    if (mounted) _schedule();
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value.replaceAll(' ', '')));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$label copiada.')));
  }

  @override
  Widget build(BuildContext context) {
    final details = [
      for (final d in (_p['details'] as List? ?? const []))
        Map<String, dynamic>.from(d as Map),
    ];
    final message = _p['message'] as String? ?? '';
    final openUrl = _p['openUrl'] as String?;
    final paid = _status == 'paid';
    final waiting = !_done;
    final color = paid
        ? BazaColors.green
        : waiting
        ? const Color(0xFF9A6A00)
        : BazaColors.red;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _p['title'] as String? ?? 'Pagamento',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            if ((_p['method'] as String?)?.isNotEmpty ?? false)
              Text(
                _p['method'] as String,
                style: const TextStyle(color: BazaColors.muted),
              ),
            const SizedBox(height: 12),
            // Estado, em letra grande e com cor.
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: color.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  if (waiting)
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: color,
                      ),
                    )
                  else
                    Icon(
                      paid ? Icons.check_circle : Icons.error_outline,
                      color: color,
                      size: 26,
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _p['statusText'] as String? ?? '',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (details.isNotEmpty) ...[
              const SizedBox(height: 14),
              for (final d in details)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              d['label'] as String? ?? '',
                              style: const TextStyle(color: BazaColors.muted),
                            ),
                            SelectableText(
                              d['value'] as String? ?? '',
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (d['copy'] == true)
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 44),
                          ),
                          onPressed: () => _copy(
                            d['label'] as String? ?? '',
                            d['value'] as String? ?? '',
                          ),
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copiar'),
                        ),
                    ],
                  ),
                ),
            ],
            if (message.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(message, style: const TextStyle(fontSize: 15)),
            ],
            if (_p['simulated'] == true && waiting)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Modo de teste: esta referência dá-se por paga sozinha, sem dinheiro real.',
                  style: TextStyle(color: BazaColors.muted, fontSize: 13),
                ),
              ),
            if (openUrl != null && openUrl.isNotEmpty) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse(openUrl),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_new),
                label: Text(_p['openLabel'] as String? ?? 'Abrir'),
              ),
            ],
            const SizedBox(height: 16),
            if (_p['amount'] != null && waiting)
              Text(
                'Valor: ${kz((_p['amount'] as num).round())}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: BazaColors.muted),
              ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(paid),
              child: Text(
                paid
                    ? 'Concluir'
                    : waiting
                    ? 'Fechar (pago mais tarde)'
                    : 'Fechar',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
