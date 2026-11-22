import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../state/session.dart';
import '../widgets/common.dart';

/// Carteira do passageiro (paga corridas) ou do motorista (recebe ganhos,
/// paga comissões e pode levantar para o banco). São carteiras separadas.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await context.read<Session>().api.get('/wallet');
      if (mounted) {
        setState(() {
          _data = data;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _refreshAll() =>
      Future.wait([_load(), context.read<Session>().refreshUser()]);

  Future<void> _topUp() async {
    final amount = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Carregar carteira',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 6, 24, 8),
              child: Text(
                'Ambiente de teste: o pagamento é simulado e aprovado de imediato.',
                textAlign: TextAlign.center,
                style: TextStyle(color: BazaColors.muted),
              ),
            ),
            for (final a in const [1000, 2000, 5000, 10000])
              ListTile(
                leading: const Icon(Icons.add_circle_outline),
                title: Text(kz(a)),
                onTap: () => Navigator.pop(context, a),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (amount == null || !mounted) return;
    final session = context.read<Session>();
    setState(() => _busy = true);
    try {
      await session.api.post('/wallet/topup', {'amount': amount});
      await _refreshAll();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _withdraw(int balance, int minimum) async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _WithdrawSheet(balance: balance, minimum: minimum),
    );
    if (done == true && mounted) {
      await _refreshAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pedido de levantamento registado.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(title: const Text('Carteira')),
      body: data == null
          ? Center(
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
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _balanceCard(data),
                  for (final w
                      in data['pendingWithdrawals'] as List? ?? const [])
                    _pendingWithdrawal(w as Map<String, dynamic>),
                  const SizedBox(height: 24),
                  const Text(
                    'Movimentos',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  if ((data['transactions'] as List).isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'Ainda não há movimentos.',
                        style: TextStyle(color: BazaColors.muted),
                      ),
                    ),
                  for (final t in data['transactions'] as List)
                    _txTile(t as Map<String, dynamic>),
                ],
              ),
            ),
    );
  }

  Widget _balanceCard(Map<String, dynamic> data) {
    final balance = (data['balance'] as num).round();
    final canTopUp = data['topupAvailable'] == true;
    final canWithdraw = data['canWithdraw'] == true;
    final minimum = (data['minWithdrawal'] as num? ?? 0).round();
    final debtLimit = (data['debtLimit'] as num?)?.round();
    final overLimit = debtLimit != null && balance < -debtLimit;
    const onDark = TextStyle(color: Colors.white70, fontSize: 13);
    final darkButton = FilledButton.styleFrom(
      disabledBackgroundColor: Colors.white24,
      disabledForegroundColor: Colors.white60,
      minimumSize: const Size.fromHeight(48),
    );

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: BazaColors.ink,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            canWithdraw ? 'Saldo de motorista' : 'Saldo disponível',
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 6),
          Text(
            kz(balance),
            style: TextStyle(
              color: balance < 0 ? const Color(0xFFFCA5A5) : Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.w900,
            ),
          ),
          if (balance < 0 && debtLimit != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                overLimit
                    ? 'Tem comissões por pagar acima do limite de ${kz(debtLimit)}. Carregue a carteira para voltar a ficar online.'
                    : 'Saldo negativo: comissões das corridas pagas em dinheiro. Limite: ${kz(debtLimit)}.',
                style: onDark,
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: canTopUp && !_busy ? _topUp : null,
                  style: darkButton,
                  icon: const Icon(Icons.add),
                  label: Text(_busy ? 'A carregar…' : 'Carregar'),
                ),
              ),
              if (canWithdraw) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: balance >= minimum && !_busy
                        ? () => _withdraw(balance, minimum)
                        : null,
                    style: darkButton.copyWith(
                      backgroundColor: WidgetStateProperty.resolveWith(
                        (s) => s.contains(WidgetState.disabled)
                            ? Colors.white24
                            : Colors.white,
                      ),
                    ),
                    icon: const Icon(Icons.account_balance_outlined),
                    label: const Text('Levantar'),
                  ),
                ),
              ],
            ],
          ),
          if (!canTopUp)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Carregamentos por Multicaixa Express disponíveis em breve.',
                style: onDark,
              ),
            ),
          if (canWithdraw && balance < minimum)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Levantamento mínimo: ${kz(minimum)}.',
                style: onDark,
              ),
            ),
        ],
      ),
    );
  }

  Widget _pendingWithdrawal(Map<String, dynamic> w) {
    final iban = w['iban'] as String;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BazaColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.schedule, color: BazaColors.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Levantamento de ${kz((w['amount'] as num).round())} em processamento',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  'Para o IBAN terminado em ${iban.substring(iban.length - 4)}',
                  style: const TextStyle(color: BazaColors.muted, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _txTile(Map<String, dynamic> t) {
    final amount = (t['amount'] as num).round();
    final credit = amount > 0;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: BazaColors.surface,
        foregroundColor: credit ? BazaColors.green : BazaColors.ink,
        child: Icon(credit ? Icons.south_west : Icons.north_east, size: 20),
      ),
      title: Text(t['description'] as String? ?? ''),
      subtitle: Text(
        dateTime(DateTime.parse(t['createdAt'] as String).toLocal()),
      ),
      trailing: Text(
        '${credit ? '+' : ''}${kz(amount)}',
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: credit ? BazaColors.green : BazaColors.ink,
        ),
      ),
    );
  }
}

/// Formulário de levantamento do saldo do motorista para o banco.
class _WithdrawSheet extends StatefulWidget {
  const _WithdrawSheet({required this.balance, required this.minimum});
  final int balance, minimum;

  @override
  State<_WithdrawSheet> createState() => _WithdrawSheetState();
}

class _WithdrawSheetState extends State<_WithdrawSheet> {
  /// A tecla Enter no último campo faz o mesmo que o botão principal.
  final _submitKey = GlobalKey<AsyncButtonState>();

  late final _amount = TextEditingController(text: '${widget.balance}');
  final _iban = TextEditingController(text: 'AO06');

  @override
  void dispose() {
    _amount.dispose();
    _iban.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final amount = int.tryParse(_amount.text) ?? 0;
    if (amount < widget.minimum) throw 'O mínimo é ${kz(widget.minimum)}.';
    if (amount > widget.balance)
      throw 'O valor é superior ao saldo (${kz(widget.balance)}).';
    final iban = _iban.text.replaceAll(' ', '').toUpperCase();
    if (!RegExp(r'^AO\d{23}$').hasMatch(iban))
      throw 'IBAN inválido: AO06 seguido de 21 dígitos.';
    final navigator = Navigator.of(context);
    await context.read<Session>().api.post('/wallet/withdraw', {
      'amount': amount,
      'iban': iban,
    });
    navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Sobe com o teclado.
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Levantar para o banco',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              'Saldo disponível: ${kz(widget.balance)}. O valor sai já da carteira e a transferência é feita nos dias úteis seguintes.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: BazaColors.muted),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _amount,
              textInputAction: TextInputAction.next,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Valor',
                suffixText: 'Kz',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _iban,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submitKey.currentState?.trigger(),
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'IBAN',
                hintText: 'AO06 0000 0000 0000 0000 0000 0',
              ),
            ),
            const SizedBox(height: 20),
            AsyncButton(
              key: _submitKey,
              label: 'Pedir levantamento',
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
