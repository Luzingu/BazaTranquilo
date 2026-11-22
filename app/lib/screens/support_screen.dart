import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../state/session.dart';
import '../widgets/common.dart';

const ticketCategories = {
  'lost_item': 'Objecto perdido',
  'ride': 'Problema com uma corrida',
  'payment': 'Pagamento',
  'safety': 'Segurança',
  'account': 'A minha conta',
  'other': 'Outro assunto',
};

/// Ajuda e suporte: contactos da equipa, regras úteis e pedidos de ajuda.
/// Aberto a partir de uma corrida do histórico, o pedido fica ligado a ela.
class SupportScreen extends StatefulWidget {
  const SupportScreen({super.key, this.ride, this.category});
  final Ride? ride;
  final String? category;

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen> {
  final _message = TextEditingController();
  final _submitKey = GlobalKey<AsyncButtonState>();
  late final _api = context.read<Session>().api;
  late String _category =
      widget.category ?? (widget.ride != null ? 'ride' : 'other');

  Map<String, dynamic>? _info;
  List<Map<String, dynamic>> _tickets = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final info = await _api.get('/support/info');
      final res = await _api.get('/support/tickets');
      if (!mounted) return;
      setState(() {
        _info = info;
        _tickets = [
          for (final t in res['tickets'] as List)
            Map<String, dynamic>.from(t as Map),
        ];
      });
    } on ApiException {
      // Sem rede: o formulário continua disponível.
    }
  }

  Future<void> _send() async {
    final text = _message.text.trim();
    if (text.length < 10) throw 'Descreva o que aconteceu, com algum detalhe.';
    await _api.post('/support/tickets', {
      'category': _category,
      'message': text,
      if (widget.ride != null) 'rideId': widget.ride!.id,
    });
    if (!mounted) return;
    _message.clear();
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Pedido enviado. A equipa responde aqui, nesta página.'),
      ),
    );
    await _load();
  }

  Future<void> _open(Uri uri) async {
    final ok = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);
    if (!ok && mounted)
      showError(context, 'Não foi possível abrir neste telemóvel.');
  }

  @override
  Widget build(BuildContext context) {
    const section = TextStyle(fontWeight: FontWeight.w700, fontSize: 16);
    final info = _info;
    final phone = info?['phone'] as String?;
    final email = info?['email'] as String?;
    final rules = info?['cancellation'] as Map?;
    final ride = widget.ride;
    return Scaffold(
      appBar: AppBar(title: const Text('Ajuda e suporte')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          if (phone != null || email != null) ...[
            const Text('Falar com a equipa', style: section),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                if (phone != null)
                  OutlinedButton.icon(
                    onPressed: () => _open(Uri(scheme: 'tel', path: phone)),
                    icon: const Icon(Icons.phone, size: 18),
                    label: Text(phone),
                  ),
                if (email != null)
                  OutlinedButton.icon(
                    onPressed: () => _open(Uri(scheme: 'mailto', path: email)),
                    icon: const Icon(Icons.mail_outline, size: 18),
                    label: Text(email),
                  ),
              ],
            ),
            const SizedBox(height: 22),
          ],
          const Text('Enviar um pedido', style: section),
          const SizedBox(height: 4),
          const Text(
            'Em perigo? Use o botão SOS da corrida ou ligue para a emergência. Este formulário não é para urgências.',
            style: TextStyle(color: BazaColors.muted, fontSize: 13),
          ),
          if (ride != null)
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: BazaColors.surface,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                'Sobre a corrida de ${dateTime(ride.createdAt)}\n${ride.pickup.address} → ${ride.dropoff.address}',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _category,
            decoration: const InputDecoration(labelText: 'Assunto'),
            items: [
              for (final e in ticketCategories.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) => setState(() => _category = v ?? _category),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _message,
            minLines: 4,
            maxLines: 8,
            maxLength: 1500,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'O que aconteceu?',
              alignLabelWithHint: true,
              hintText: _category == 'lost_item'
                  ? 'Descreva o objecto e onde o deixou (banco de trás, mala…).'
                  : 'Conte-nos o que se passou, com o máximo de detalhe.',
            ),
          ),
          const SizedBox(height: 8),
          AsyncButton(
            key: _submitKey,
            label: 'Enviar pedido',
            onPressed: _send,
          ),
          if (_tickets.isNotEmpty) ...[
            const SizedBox(height: 28),
            const Text('Os seus pedidos', style: section),
            for (final t in _tickets) _TicketCard(ticket: t),
          ],
          if (rules != null) ...[
            const SizedBox(height: 28),
            const Text('Cancelamentos', style: section),
            const SizedBox(height: 6),
            Text(
              'Pode cancelar sem penalização enquanto se procura motorista e até '
              '${((rules['graceSeconds'] as num) / 60).round()} minutos depois de um motorista aceitar. '
              'Cancelar mais tarde, ou com o motorista já no local, conta como cancelamento tardio. '
              '${rules['maxLate']} cancelamentos tardios em 24 horas suspendem a conta durante '
              '${rules['suspendMinutes']} minutos. Para os motoristas, desistir de uma corrida aceite conta sempre.',
              style: const TextStyle(color: BazaColors.muted),
            ),
          ],
          const SizedBox(height: 22),
          const LegalLinks(),
        ],
      ),
    );
  }
}

class _TicketCard extends StatelessWidget {
  const _TicketCard({required this.ticket});
  final Map<String, dynamic> ticket;

  @override
  Widget build(BuildContext context) {
    final resolved = ticket['status'] == 'resolved';
    final reply = ticket['reply'] as String?;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BazaColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  ticketCategories[ticket['category']] ?? 'Pedido',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: resolved ? BazaColors.green : BazaColors.yellow,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  resolved ? 'Respondido' : 'Em análise',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: resolved ? Colors.white : BazaColors.ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${ticket['message']}',
            style: const TextStyle(color: BazaColors.muted),
          ),
          if (reply != null) ...[
            const Divider(height: 20),
            const Text(
              'Resposta da equipa',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(reply),
          ],
        ],
      ),
    );
  }
}
