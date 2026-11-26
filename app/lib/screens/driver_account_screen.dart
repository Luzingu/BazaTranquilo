import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../state/session.dart';
import '../widgets/common.dart';
import '../widgets/payment_session.dart';

const _methodLabels = {
  'transfer': 'Transferência ou depósito',
  'cash': 'Dinheiro, entregue à equipa',
};

/// O saldo do motorista no Bazá (pré-pago): carregar por referência (gerada
/// pelo servidor) ou comunicar uma transferência, ver as viagens grátis, pagar a
/// mensalidade das viaturas de preço combinado com o saldo e os movimentos.
/// Os textos de regras vêm do servidor (`note`), para mudarem sem nova versão.
class DriverAccountScreen extends StatefulWidget {
  const DriverAccountScreen({super.key});

  @override
  State<DriverAccountScreen> createState() => _DriverAccountScreenState();
}

class _DriverAccountScreenState extends State<DriverAccountScreen> {
  late final _api = context.read<Session>().api;
  Map<String, dynamic>? _data;
  String? _error;

  /// Referência ainda por pagar (a última gerada), para a voltar a mostrar.
  Map<String, dynamic>? _pendingTopup;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await _api.get('/driver/account');
      final topups = await _api
          .get('/driver/topups')
          .catchError((_) => <String, dynamic>{});
      if (mounted) {
        setState(() {
          _data = res;
          _error = null;
          _pendingTopup = [
            for (final p in (topups['payments'] as List? ?? const []))
              Map<String, dynamic>.from(p as Map),
          ].where((p) => p['status'] == 'pending').firstOrNull;
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
      isDismissible: false,
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

  Map<String, dynamic> get _balance =>
      Map<String, dynamic>.from(_data?['balance'] as Map? ?? const {});

  /// Carregar o saldo: referência gerada pelo servidor, ou comunicar uma
  /// transferência quando as referências ainda não estão disponíveis.
  Future<void> _topUp() async {
    final topup = Map<String, dynamic>.from(_balance['topup'] as Map? ?? {});
    final result = await showModalBottomSheet<Object>(
      context: context,
      isDismissible: false,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TopupSheet(
        api: _api,
        topup: topup,
        payInfo: _data?['payInfo'] as String? ?? '',
      ),
    );
    if (!mounted) return;
    if (result is Map) {
      await showPaymentSession(
        context,
        _api,
        Map<String, dynamic>.from(result),
      );
    } else if (result == 'manual') {
      await _pay();
      return;
    }
    await _load();
    if (mounted) context.read<Session>().refreshUser().catchError((_) {});
  }

  /// Mensalidade de uma viatura de preço combinado, paga com o saldo.
  Future<void> _paySubscription(Map<String, dynamic> vehicle) async {
    final paid = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: false,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SubscriptionSheet(
        api: _api,
        vehicle: vehicle,
        balance: (_balance['amount'] as num? ?? 0).round(),
      ),
    );
    if (paid == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mensalidade paga com o saldo.')),
      );
    }
    await _load();
    if (mounted) context.read<Session>().refreshUser().catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    const section = TextStyle(fontWeight: FontWeight.w700, fontSize: 16);
    final data = _data;
    if (data == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('O meu saldo')),
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
    final balance = (_balance['amount'] as num? ?? 0).round();
    final freeRides = (_balance['freeRidesLeft'] as num? ?? 0).round();
    final note = data['note'] is Map
        ? Map<String, dynamic>.from(data['note'] as Map)
        : null;
    final vehicles = _list('vehicles');
    final requests = _list('requests');
    final entries = _list('entries');
    final pendingKinds = {
      for (final r in requests)
        if (r['status'] == 'pending') '${r['kind']}:${r['vehicleId'] ?? ''}',
    };
    final pending = _pendingTopup;

    return Scaffold(
      appBar: AppBar(title: const Text('O meu saldo')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            // Saldo em destaque, com as viagens grátis e a regra (do servidor).
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: BazaColors.ink,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Saldo',
                    style: TextStyle(color: Colors.white70, fontSize: 15),
                  ),
                  Text(
                    kz(balance),
                    style: TextStyle(
                      color: balance < 0
                          ? const Color(0xFFFF8A80)
                          : Colors.white,
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  if (freeRides > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.card_giftcard,
                            color: BazaColors.yellow,
                            size: 20,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            freeRides == 1
                                ? '1 viagem grátis'
                                : '$freeRides viagens grátis',
                            style: const TextStyle(
                              color: BazaColors.yellow,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (note != null &&
                      (note['detail'] as String? ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        note['detail'] as String,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  const SizedBox(height: 14),
                  // Taxa a 0 %: gratuito, não há nada a carregar.
                  if (_balance['free'] == true)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: BazaColors.green.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.check_circle,
                            color: Colors.white,
                            size: 26,
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Gratuito: não paga nada ao Bazá.',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: BazaColors.yellow,
                        foregroundColor: BazaColors.ink,
                      ),
                      onPressed: _topUp,
                      icon: const Icon(Icons.add_card),
                      label: const Text('Carregar saldo'),
                    ),
                ],
              ),
            ),
            if (pending != null)
              Card(
                margin: const EdgeInsets.only(top: 14),
                child: ListTile(
                  leading: const Icon(Icons.receipt_long, size: 30),
                  title: Text(
                    'Referência por pagar · ${kz((pending['amount'] as num).round())}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text(
                    'Toque para ver a entidade e a referência.',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await showPaymentSession(context, _api, pending);
                    await _load();
                  },
                ),
              ),
            if (vehicles.isNotEmpty) ...[
              const SizedBox(height: 26),
              const Text('Mensalidade por viatura', style: section),
              const SizedBox(height: 4),
              const Text(
                'Triciclos, XL, carrinhas e camiões combinam o preço com o cliente e não descontam taxa por corrida. Cada viatura paga a sua mensalidade, com o saldo.',
                style: TextStyle(color: BazaColors.muted, fontSize: 13),
              ),
              for (final v in vehicles)
                _VehicleCard(
                  vehicle: v,
                  pending: pendingKinds.contains('subscription:${v['id']}'),
                  onPay: () => _paySubscription(v),
                ),
            ],
            if (requests.isNotEmpty) ...[
              const SizedBox(height: 26),
              const Text('Carregamentos comunicados', style: section),
              for (final r in requests)
                _RequestTile(request: r, onCancel: () => _cancel(r)),
            ],
            if (entries.isNotEmpty) ...[
              const SizedBox(height: 26),
              const Text('Movimentos do saldo', style: section),
              for (final e in entries.take(15))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    e['type'] == 'charge' || e['type'] == 'payout'
                        ? Icons.north_east
                        : Icons.south_west,
                    color: e['type'] == 'charge' || e['type'] == 'payout'
                        ? BazaColors.muted
                        : BazaColors.green,
                  ),
                  title: Text(switch (e['type']) {
                    'payment' =>
                      (e['note'] as String?) ?? 'Carregamento do saldo',
                    'credit' =>
                      (e['note'] as String?) ??
                          'Corrida por conta de uma empresa',
                    'payout' => 'Saldo devolvido',
                    _ => (e['note'] as String?) ?? 'Taxa de uma corrida',
                  }),
                  subtitle: Text(
                    dateTime(
                      DateTime.parse(e['createdAt'] as String).toLocal(),
                    ),
                  ),
                  trailing: Text(
                    '${e['type'] == 'charge' || e['type'] == 'payout' ? '−' : '+'} ${kz((e['amount'] as num).round())}',
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
  late final _amount = TextEditingController(
    text: widget.commissionDue > 0 ? '${widget.commissionDue}' : '',
  );
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
                  ? 'Comunicar carregamento'
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
                  labelText: 'Valor que transferiu ou entregou',
                  suffixText: 'Kz',
                  helperText: 'Entra no saldo quando a equipa confirmar.',
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

/// Quanto carregar: valores sugeridos (do servidor) ou outro valor. Devolve a
/// sessão de pagamento criada, ou 'manual' para comunicar uma transferência.
class _TopupSheet extends StatefulWidget {
  const _TopupSheet({
    required this.api,
    required this.topup,
    required this.payInfo,
  });
  final ApiClient api;
  final Map<String, dynamic> topup;
  final String payInfo;

  @override
  State<_TopupSheet> createState() => _TopupSheetState();
}

class _TopupSheetState extends State<_TopupSheet> {
  late final List<int> _presets = [
    for (final v
        in (widget.topup['presets'] as List? ?? const [1000, 2000, 5000]))
      (v as num).round(),
  ];
  late int _amount = _presets.length > 1 ? _presets[1] : 2000;
  final _custom = TextEditingController();

  bool get _available => widget.topup['available'] == true;

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final navigator = Navigator.of(context);
    final res = await widget.api.post('/driver/topup', {'amount': _amount});
    navigator.pop(Map<String, dynamic>.from(res['payment'] as Map));
  }

  @override
  Widget build(BuildContext context) {
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
            const Text(
              'Carregar saldo',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            if (_available) ...[
              const Text(
                'Quanto quer carregar?',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final v in _presets)
                    ChoiceChip(
                      label: Text(kz(v), style: const TextStyle(fontSize: 16)),
                      selected: _amount == v && _custom.text.isEmpty,
                      onSelected: (_) => setState(() {
                        _custom.clear();
                        _amount = v;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _custom,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(7),
                ],
                decoration: InputDecoration(
                  labelText: 'Outro valor',
                  suffixText: 'Kz',
                  helperText:
                      'Entre ${kz((widget.topup['min'] as num? ?? 500).round())} e ${kz((widget.topup['max'] as num? ?? 500000).round())}',
                ),
                onChanged: (t) =>
                    setState(() => _amount = int.tryParse(t) ?? 0),
              ),
              const SizedBox(height: 14),
              AsyncButton(
                label:
                    '${widget.topup['label'] as String? ?? 'Gerar referência'} · ${kz(_amount)}',
                onPressed: _amount > 0 ? _generate : null,
              ),
              const SizedBox(height: 6),
              const Text(
                'Recebe uma entidade e uma referência para pagar no Multicaixa, no Multicaixa Express ou no banco. O saldo aumenta sozinho depois do pagamento.',
                style: TextStyle(color: BazaColors.muted, fontSize: 13),
              ),
              const Divider(height: 28),
            ] else if (widget.payInfo.isNotEmpty) ...[
              Text(widget.payInfo),
              const SizedBox(height: 12),
            ],
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop('manual'),
              icon: const Icon(Icons.receipt_long),
              label: const Text('Já transferi ou paguei em dinheiro'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pagar meses de mensalidade de uma viatura com o saldo.
class _SubscriptionSheet extends StatefulWidget {
  const _SubscriptionSheet({
    required this.api,
    required this.vehicle,
    required this.balance,
  });
  final ApiClient api;
  final Map<String, dynamic> vehicle;
  final int balance;

  @override
  State<_SubscriptionSheet> createState() => _SubscriptionSheetState();
}

class _SubscriptionSheetState extends State<_SubscriptionSheet> {
  int _months = 1;

  @override
  Widget build(BuildContext context) {
    final fee = (widget.vehicle['fee'] as num? ?? 0).round();
    final total = fee * _months;
    final enough = widget.balance >= total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Mensalidade · ${widget.vehicle['plate']}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
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
          const SizedBox(height: 12),
          Text(
            'Total: ${kz(total)}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          Text(
            'O seu saldo: ${kz(widget.balance)}',
            style: TextStyle(color: enough ? BazaColors.muted : BazaColors.red),
          ),
          const SizedBox(height: 14),
          AsyncButton(
            label: enough ? 'Pagar com o saldo' : 'Saldo insuficiente',
            onPressed: enough
                ? () async {
                    final navigator = Navigator.of(context);
                    await widget.api.post('/driver/subscription/pay', {
                      'vehicleId': widget.vehicle['id'],
                      'months': _months,
                    });
                    navigator.pop(true);
                  }
                : null,
          ),
          if (!enough)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Carregue o saldo primeiro (botão «Carregar saldo»).',
                style: TextStyle(color: BazaColors.muted, fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }
}
