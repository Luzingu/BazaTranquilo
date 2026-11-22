import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../state/session.dart';
import '../widgets/common.dart';

const _methodLabels = {
  'transfer': 'Transferência ou depósito',
  'cash': 'Dinheiro, entregue à equipa',
};

/// Pagamentos do motorista ao Bazá: a mensalidade de cada viatura de preço
/// combinado e as comissões das corridas em dinheiro. O motorista paga pelos
/// meios indicados e comunica aqui o pagamento; a equipa confirma-o.
class DriverAccountScreen extends StatefulWidget {
  const DriverAccountScreen({super.key});

  @override
  State<DriverAccountScreen> createState() => _DriverAccountScreenState();
}

class _DriverAccountScreenState extends State<DriverAccountScreen> {
  late final _api = context.read<Session>().api;
  Map<String, dynamic>? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await _api.get('/driver/account');
      if (mounted) {
        setState(() {
          _data = res;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  List<Map<String, dynamic>> _list(String key) => [
    for (final v in (_data?[key] as List? ?? const []))
      Map<String, dynamic>.from(v as Map),
  ];

  /// Folha para comunicar um pagamento: mensalidade de [vehicle] ou comissões.
  Future<void> _pay({Map<String, dynamic>? vehicle}) async {
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PaySheet(
        api: _api,
        vehicle: vehicle,
        commissionDue: ((_data?['commission'] as Map?)?['due'] as num? ?? 0)
            .round(),
        payInfo: _data?['payInfo'] as String? ?? '',
        methods: [
          for (final m
              in (_data?['methods'] as List? ?? const ['transfer', 'cash']))
            '$m',
        ],
      ),
    );
    if (sent == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Pagamento comunicado. A equipa confirma assim que o verificar.',
          ),
        ),
      );
      await _load();
      if (mounted) context.read<Session>().refreshUser().catchError((_) {});
    }
  }

  Future<void> _cancel(Map<String, dynamic> request) async {
    try {
      await _api.delete('/driver/payments/${request['id']}');
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    const section = TextStyle(fontWeight: FontWeight.w700, fontSize: 16);
    final data = _data;
    if (data == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Pagamentos e mensalidades')),
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator(color: BazaColors.ink)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!),
                    TextButton(
                      onPressed: _load,
                      child: const Text('Tentar novamente'),
                    ),
                  ],
                ),
        ),
      );
    }
    final commission = Map<String, dynamic>.from(data['commission'] as Map);
    final due = (commission['due'] as num).round();
    final rate = (commission['rate'] as num).toDouble() * 100;
    final vehicles = _list('vehicles');
    final requests = _list('requests');
    final entries = _list('entries');
    final pendingKinds = {
      for (final r in requests)
        if (r['status'] == 'pending') '${r['kind']}:${r['vehicleId'] ?? ''}',
    };
    final payInfo = data['payInfo'] as String? ?? '';

    return Scaffold(
      appBar: AppBar(title: const Text('Pagamentos e mensalidades')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            if (payInfo.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(14),
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF4CC),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Como pagar',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(payInfo),
                    const SizedBox(height: 4),
                    const Text(
                      'Depois de pagar, comunique aqui o pagamento para a equipa o confirmar.',
                      style: TextStyle(color: BazaColors.muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
            const Text('Mensalidade por viatura', style: section),
            const SizedBox(height: 4),
            const Text(
              'Triciclos, XL, carrinhas e camiões combinam o preço com o cliente e não pagam comissão por serviço. Cada viatura registada paga a sua mensalidade.',
              style: TextStyle(color: BazaColors.muted, fontSize: 13),
            ),
            if (vehicles.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text(
                  'Não tem viaturas deste tipo registadas.',
                  style: TextStyle(color: BazaColors.muted),
                ),
              ),
            for (final v in vehicles)
              _VehicleCard(
                vehicle: v,
                pending: pendingKinds.contains('subscription:${v['id']}'),
                onPay: () => _pay(vehicle: v),
              ),
            const SizedBox(height: 26),
            const Text('Comissões das corridas', style: section),
            const SizedBox(height: 4),
            Text(
              'Nas corridas de moto e de carro, o Bazá fica com ${rate.toStringAsFixed(rate % 1 == 0 ? 0 : 1).replaceAll('.', ',')} % do valor. '
              'Quando o passageiro paga em dinheiro, a comissão fica por pagar.',
              style: const TextStyle(color: BazaColors.muted, fontSize: 13),
            ),
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: BazaColors.surface,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Saldo negativo: o Bazá deve ao motorista (corridas por
                        // conta de empresas, que o passageiro não paga).
                        Text(
                          due < 0 ? 'A receber do Bazá' : 'Por pagar',
                          style: const TextStyle(color: BazaColors.muted),
                        ),
                        Text(
                          kz(due.abs()),
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        if (commission['enforced'] == true)
                          Text(
                            'Limite para continuar online: ${kz((commission['limit'] as num).round())}',
                            style: const TextStyle(
                              color: BazaColors.muted,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (pendingKinds.contains('commission:'))
                    const Text(
                      'A confirmar…',
                      style: TextStyle(color: BazaColors.muted),
                    )
                  else if (due > 0)
                    FilledButton(
                      style: _compact,
                      onPressed: () => _pay(),
                      child: const Text('Pagar'),
                    ),
                ],
              ),
            ),
            if (requests.isNotEmpty) ...[
              const SizedBox(height: 26),
              const Text('Pagamentos comunicados', style: section),
              for (final r in requests)
                _RequestTile(request: r, onCancel: () => _cancel(r)),
            ],
            if (entries.isNotEmpty) ...[
              const SizedBox(height: 26),
              const Text('Movimentos das comissões', style: section),
              for (final e in entries.take(15))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    e['type'] == 'charge' ? Icons.north_east : Icons.south_west,
                    color: e['type'] == 'charge'
                        ? BazaColors.muted
                        : BazaColors.green,
                  ),
                  title: Text(switch (e['type']) {
                    'payment' => 'Pagamento seu ao Bazá',
                    'credit' =>
                      (e['note'] as String?) ??
                          'Corrida por conta de uma empresa',
                    'payout' => 'O Bazá pagou-lhe',
                    _ => (e['note'] as String?) ?? 'Comissão de uma corrida',
                  }),
                  subtitle: Text(
                    dateTime(
                      DateTime.parse(e['createdAt'] as String).toLocal(),
                    ),
                  ),
                  trailing: Text(
                    '${e['type'] == 'charge' || e['type'] == 'payout' ? '+' : '−'} ${kz((e['amount'] as num).round())}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// O tema dá a largura total aos botões; dentro de uma linha ficam à medida.
final _compact = FilledButton.styleFrom(
  minimumSize: const Size(0, 44),
  padding: const EdgeInsets.symmetric(horizontal: 18),
);

class _VehicleCard extends StatelessWidget {
  const _VehicleCard({
    required this.vehicle,
    required this.pending,
    required this.onPay,
  });
  final Map<String, dynamic> vehicle;
  final bool pending;
  final VoidCallback onPay;

  @override
  Widget build(BuildContext context) {
    final fee = (vehicle['fee'] as num).round();
    final until = vehicle['paidUntil'] == null
        ? null
        : DateTime.parse(vehicle['paidUntil'] as String).toLocal();
    final (String label, Color color) = switch (vehicle['state']) {
      'expired' => ('Em atraso desde ${date(until!)}', BazaColors.red),
      'active' => ('Em dia até ${date(until!)}', BazaColors.green),
      'trial' => ('Período grátis começa ao ficar online', BazaColors.muted),
      _ => ('Sem mensalidade por agora', BazaColors.muted),
    };
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
              Icon(
                categoryIcons[vehicle['category']] ??
                    Icons.local_shipping_outlined,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${vehicle['categoryLabel']} · ${vehicle['plate']}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              if (vehicle['active'] == true)
                const Text(
                  'Em uso',
                  style: TextStyle(color: BazaColors.muted, fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${vehicle['label']}',
            style: const TextStyle(color: BazaColors.muted),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
          if (fee > 0) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${kz(fee)} por mês',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (pending)
                  const Text(
                    'A confirmar…',
                    style: TextStyle(color: BazaColors.muted),
                  )
                else
                  FilledButton(
                    style: _compact,
                    onPressed: onPay,
                    child: const Text('Pagar mensalidade'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({required this.request, required this.onCancel});
  final Map<String, dynamic> request;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final status = request['status'];
    final (String label, Color color) = switch (status) {
      'confirmed' => ('Confirmado', BazaColors.green),
      'rejected' => ('Não confirmado', BazaColors.red),
      _ => ('A aguardar confirmação', BazaColors.muted),
    };
    final what = request['kind'] == 'subscription'
        ? 'Mensalidade · ${request['plate'] ?? ''} · ${request['months']} ${request['months'] == 1 ? 'mês' : 'meses'}'
        : 'Comissões';
    final note = request['note'] as String?;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('$what · ${kz((request['amount'] as num).round())}'),
      subtitle: Text(
        '$label · ${dateTime(DateTime.parse(request['createdAt'] as String).toLocal())}${note == null || note.isEmpty ? '' : '\n$note'}',
        style: TextStyle(color: color),
      ),
      trailing: status == 'pending'
          ? TextButton(onPressed: onCancel, child: const Text('Anular'))
          : null,
    );
  }
}

class _PaySheet extends StatefulWidget {
  const _PaySheet({
    required this.api,
    required this.vehicle,
    required this.commissionDue,
    required this.payInfo,
    required this.methods,
  });
  final ApiClient api;
  final Map<String, dynamic>? vehicle;
  final int commissionDue;
  final String payInfo;
  final List<String> methods;

  @override
  State<_PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<_PaySheet> {
  final _reference = TextEditingController();
  late final _amount = TextEditingController(text: '${widget.commissionDue}');
  int _months = 1;
  late String _method = widget.methods.firstOrNull ?? 'transfer';

  @override
  void dispose() {
    _reference.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final vehicle = widget.vehicle;
    final navigator = Navigator.of(context);
    final reference = _reference.text.trim();
    if (_method == 'transfer' && reference.length < 3) {
      throw 'Escreva o número do comprovativo da transferência ou do depósito.';
    }
    final amount = int.tryParse(_amount.text);
    if (vehicle == null && (amount == null || amount <= 0))
      throw 'Indique o valor que pagou.';
    await widget.api.post('/driver/payments', {
      'kind': vehicle == null ? 'commission' : 'subscription',
      if (vehicle != null) 'vehicleId': vehicle['id'],
      if (vehicle != null) 'months': _months,
      if (vehicle == null) 'amount': amount,
      'method': _method,
      if (reference.isNotEmpty) 'reference': reference,
    });
    navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final vehicle = widget.vehicle;
    final fee = (vehicle?['fee'] as num? ?? 0).round();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              vehicle == null
                  ? 'Pagar comissões'
                  : 'Mensalidade · ${vehicle['plate']}',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            if (widget.payInfo.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  widget.payInfo,
                  style: const TextStyle(color: BazaColors.muted),
                ),
              ),
            const SizedBox(height: 14),
            if (vehicle != null) ...[
              const Text(
                'Quantos meses?',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final n in const [1, 2, 3, 6, 12])
                    ChoiceChip(
                      label: Text(n == 1 ? '1 mês' : '$n meses'),
                      selected: _months == n,
                      onSelected: (_) => setState(() => _months = n),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Total: ${kz(fee * _months)}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ] else
              TextField(
                controller: _amount,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(8),
                ],
                decoration: InputDecoration(
                  labelText: 'Valor pago',
                  suffixText: 'Kz',
                  helperText: 'Deve ${kz(widget.commissionDue)}',
                ),
              ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _method,
              decoration: const InputDecoration(labelText: 'Como pagou?'),
              items: [
                for (final m in widget.methods)
                  DropdownMenuItem(
                    value: m,
                    child: Text(_methodLabels[m] ?? m),
                  ),
              ],
              onChanged: (v) => setState(() => _method = v ?? _method),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reference,
              maxLength: 80,
              decoration: InputDecoration(
                labelText: _method == 'transfer'
                    ? 'N.º do comprovativo'
                    : 'Nota (opcional)',
                hintText: _method == 'transfer'
                    ? 'Ex.: n.º da operação no talão'
                    : 'Ex.: entregue ao Sr. João',
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            AsyncButton(label: 'Comunicar pagamento', onPressed: _send),
          ],
        ),
      ),
    );
  }
}
