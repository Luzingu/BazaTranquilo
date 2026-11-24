import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../state/ride_state.dart';
import '../state/session.dart';
import 'common.dart';

// Confirmar o número mais tarde.
//
// Quem cria conta quando o SMS falha entra na mesma, com o número "por
// confirmar". O app pede o código depois, sem incomodar:
// - só quando o servidor diz que o SMS está a funcionar e que a pessoa não está
//   numa corrida (nem, sendo motorista, online à espera de pedidos);
// - nunca logo ao abrir: espera um pouco, e aproveita os momentos calmos —
//   voltar ao app, ou pouco depois de acabar uma corrida;
// - "Agora não" adia cada vez mais (2 h, 12 h, depois 1 dia).
// Pode-se também confirmar a qualquer momento no menu ou em "Os meus dados".

/// Adiamentos sucessivos depois de "Agora não".
const _snoozes = [Duration(hours: 2), Duration(hours: 12), Duration(days: 1)];

/// Vigia as boas alturas para pedir a confirmação do número.
class PhoneConfirmHost extends StatefulWidget {
  const PhoneConfirmHost({super.key, required this.child});
  final Widget child;

  @override
  State<PhoneConfirmHost> createState() => _PhoneConfirmHostState();
}

class _PhoneConfirmHostState extends State<PhoneConfirmHost>
    with WidgetsBindingObserver {
  static const _storage = FlutterSecureStorage();
  late final Session _session = context.read<Session>();
  late final RideState _rides = context.read<RideState>();

  Timer? _soon, _periodic;
  bool _showing = false;
  bool _hadRide = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _rides.addListener(_onRide);
    // Não se pede nada logo ao abrir: primeiro a pessoa vê o mapa.
    _later(const Duration(seconds: 20));
    _periodic = Timer.periodic(const Duration(minutes: 15), (_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rides.removeListener(_onRide);
    _soon?.cancel();
    _periodic?.cancel();
    super.dispose();
  }

  bool get _pending => _session.user?.phoneVerified == false;

  void _later(Duration delay) {
    _soon?.cancel();
    if (_pending) _soon = Timer(delay, _check);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _later(const Duration(seconds: 8));
  }

  /// A corrida acabou: dá tempo para avaliar e só depois pergunta.
  void _onRide() {
    final hasRide = _rides.ride != null;
    if (_hadRide && !hasRide) _later(const Duration(seconds: 12));
    _hadRide = hasRide;
  }

  Future<void> _check() async {
    if (!mounted || _showing || !_pending) return;
    // Do lado do app: nada de interromper uma corrida, uma chamada ou o motorista online.
    if (_rides.ride != null || _session.inCall) return;
    if (_session.user?.isOnline ?? false) return;
    if (await _snoozed()) return;
    try {
      final res = await _session.api.get('/me/phone-confirmation');
      if (res['verified'] == true) {
        await _session.refreshUser();
        return;
      }
      if (res['canAskNow'] != true) return;
    } on ApiException {
      return; // sem rede: fica para a próxima
    }
    if (!mounted || _rides.ride != null || _showing) return;
    _showing = true;
    final result = await showPhoneConfirmSheet(context, invited: true);
    _showing = false;
    if (result == PhoneConfirmResult.later) await _snooze();
  }

  Future<bool> _snoozed() async {
    final until = int.tryParse(
      await _storage.read(key: 'phoneConfirmSnoozeUntil') ?? '',
    );
    return until != null && DateTime.now().millisecondsSinceEpoch < until;
  }

  Future<void> _snooze() async {
    final count =
        int.tryParse(await _storage.read(key: 'phoneConfirmSnoozes') ?? '') ??
        0;
    final wait = _snoozes[count.clamp(0, _snoozes.length - 1)];
    await _storage.write(key: 'phoneConfirmSnoozes', value: '${count + 1}');
    await _storage.write(
      key: 'phoneConfirmSnoozeUntil',
      value: '${DateTime.now().add(wait).millisecondsSinceEpoch}',
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

enum PhoneConfirmResult { confirmed, later }

/// Abre a janela de confirmação do número. Com [invited], foi o app a
/// propor (o botão de fechar diz "Agora não").
Future<PhoneConfirmResult> showPhoneConfirmSheet(
  BuildContext context, {
  bool invited = false,
}) async {
  final result = await showModalBottomSheet<PhoneConfirmResult>(
    context: context,
    isDismissible: false,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    builder: (_) => _PhoneConfirmSheet(invited: invited),
  );
  return result ?? PhoneConfirmResult.later;
}

class _PhoneConfirmSheet extends StatefulWidget {
  const _PhoneConfirmSheet({required this.invited});
  final bool invited;

  @override
  State<_PhoneConfirmSheet> createState() => _PhoneConfirmSheetState();
}

class _PhoneConfirmSheetState extends State<_PhoneConfirmSheet> {
  final _submitKey = GlobalKey<AsyncButtonState>();
  final _code = TextEditingController();
  bool _sent = false;
  String? _devCode;

  /// Segundos até se poder pedir outro código.
  int _wait = 0;
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final res = await context.read<Session>().api.post(
      '/me/phone-confirmation/request',
      {},
    );
    if (!mounted) return;
    setState(() {
      _sent = true;
      _devCode = res['devCode'] as String?;
      _wait = 60;
      _code.clear();
    });
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _wait--);
      if (_wait <= 0) t.cancel();
    });
  }

  Future<void> _confirm() async {
    if (_code.text.length != 6) throw 'O código tem 6 dígitos.';
    final session = context.read<Session>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await session.confirmOwnPhone(_code.text);
    navigator.pop(PhoneConfirmResult.confirmed);
    messenger.showSnackBar(
      const SnackBar(content: Text('Número confirmado. Obrigado!')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final phone = context.select<Session, String?>((s) => s.user?.phone) ?? '';
    return Padding(
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
            const CircleAvatar(
              radius: 28,
              backgroundColor: BazaColors.surface,
              child: Icon(
                Icons.mark_chat_read_outlined,
                color: BazaColors.ink,
                size: 28,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _sent ? 'Escreva o código' : 'Confirme o seu número',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            if (!_sent) ...[
              Text(
                widget.invited
                    ? 'Quando criou a conta, o SMS não chegou. Agora já está a funcionar: falta só confirmar que o $phone é seu.'
                    : 'Enviamos um código por SMS para o $phone.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: BazaColors.muted, fontSize: 15),
              ),
              const SizedBox(height: 14),
              const _Why(
                icon: Icons.lock_reset,
                text: 'Recupera a senha por SMS se a esquecer.',
              ),
              const _Why(
                icon: Icons.shield_outlined,
                text:
                    'Protege a conta: até confirmar, quem receber o código neste número pode ficar com ela.',
              ),
              const _Why(
                icon: Icons.business_center_outlined,
                text: 'Viaja por conta da sua empresa, se ela usar o Bazá.',
              ),
              const SizedBox(height: 16),
              AsyncButton(
                key: _submitKey,
                label: 'Enviar código por SMS',
                onPressed: _send,
              ),
            ] else ...[
              Text(
                'Enviámos um código de 6 dígitos para o $phone.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: BazaColors.muted, fontSize: 15),
              ),
              if (_devCode != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Modo de desenvolvimento — código: $_devCode',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: BazaColors.muted),
                  ),
                ),
              const SizedBox(height: 14),
              TextField(
                controller: _code,
                autofocus: true,
                textAlign: TextAlign.center,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submitKey.currentState?.trigger(),
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(
                  fontSize: 26,
                  letterSpacing: 10,
                  fontWeight: FontWeight.w700,
                ),
                decoration: const InputDecoration(
                  hintText: '······',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 16),
              AsyncButton(
                key: _submitKey,
                label: 'Confirmar',
                onPressed: _confirm,
              ),
              TextButton(
                onPressed: _wait > 0
                    ? null
                    : () async {
                        try {
                          await _send();
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                child: Text(
                  _wait > 0
                      ? 'Pedir outro código daqui a $_wait s'
                      : 'Não chegou? Enviar outro',
                ),
              ),
            ],
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(PhoneConfirmResult.later),
              child: Text(widget.invited ? 'Agora não' : 'Fechar'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Why extends StatelessWidget {
  const _Why({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: BazaColors.ink),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

/// Aviso "Número por confirmar" com o botão para o fazer já (menu e perfil).
class PhoneUnconfirmedTile extends StatelessWidget {
  const PhoneUnconfirmedTile({super.key});

  @override
  Widget build(BuildContext context) {
    final pending = context.select<Session, bool>(
      (s) => s.user?.phoneVerified == false,
    );
    if (!pending) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7DB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BazaColors.yellow),
      ),
      child: Row(
        children: [
          const Icon(Icons.sms_failed_outlined, color: BazaColors.ink),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Número por confirmar',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          TextButton(
            onPressed: () => showPhoneConfirmSheet(context),
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
  }
}
