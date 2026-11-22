import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../state/session.dart';
import '../widgets/common.dart';
import 'splash_screen.dart';

/// Entrada no app: escolhe-se o tipo de conta e escreve-se o número. O servidor
/// decide o passo seguinte, conforme o que está definido no painel: código SMS
/// ou senha. A senha é pedida automaticamente quando o código está desligado,
/// quando o envio do SMS falha, ou quando o código não chega.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

enum _Step { phone, code, password, agent }

class _AuthScreenState extends State<AuthScreen> {
  /// A tecla Enter no último campo faz o mesmo que o botão principal.
  final _submitKey = GlobalKey<AsyncButtonState>();

  /// Tempo de espera pelo SMS antes de se pedir a senha a quem a tem.
  static const _codeWait = Duration(seconds: 60);

  // O mesmo telefone pode ter uma conta de passageiro e outra de motorista; o
  // perfil escolhido aqui decide em qual se entra (ou se cria).
  String _role = 'passenger';
  _Step _step = _Step.phone;
  String? _sentTo; // número a que o código foi enviado / de quem é a senha
  String? _devCode;

  /// Porque se pede a senha: `otp_off`, `sms_failed` ou `no_code`.
  String? _reason;

  /// No passo do código: a conta tem senha, por isso pergunta-se se prefere
  /// entrar com ela.
  bool _canUsePassword = false;

  /// No passo do código: o campo da senha está à vista (o utilizador pediu-o
  /// ou o código demorou a chegar).
  bool _passwordToo = false;
  Timer? _waitTimer;

  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool get _isDriver => _role == 'driver';

  @override
  void dispose() {
    _waitTimer?.cancel();
    _phone.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _restart() {
    _waitTimer?.cancel();
    clearError(context);
    setState(() {
      _step = _Step.phone;
      _sentTo = null;
      _devCode = null;
      _reason = null;
      _canUsePassword = false;
      _passwordToo = false;
      _code.clear();
      _password.clear();
    });
  }

  Future<void> _start() async {
    final phone = _phone.text.replaceAll(' ', '');
    if (phone.length < 9) throw 'Escreva o seu número de telefone.';
    final session = context.read<Session>();
    final res = await session.startLogin(_role, phone);
    if (!mounted) return;
    _waitTimer?.cancel();
    final byPassword = res['method'] == 'password';
    setState(() {
      _sentTo = phone;
      _step = byPassword ? _Step.password : _Step.code;
      _reason = res['reason'] as String?;
      _devCode = res['devCode'] as String?;
      _canUsePassword = res['canUsePassword'] == true;
      _passwordToo = false;
      _code.clear();
      _password.clear();
    });
    if (!byPassword) _waitTimer = Timer(_codeWait, _codeIsLate);
  }

  /// O código não foi introduzido a tempo: se a conta tiver senha, pede-se.
  Future<void> _codeIsLate() async {
    if (!mounted || _step != _Step.code) return;
    try {
      final res = await context.read<Session>().startLogin(
        _role,
        _sentTo!,
        noCode: true,
      );
      if (!mounted || _step != _Step.code || res['method'] != 'password') {
        return;
      }
      setState(() => _passwordToo = true);
    } catch (_) {
      // Sem rede: fica à espera do código.
    }
  }

  Future<void> _enter() async {
    final session = context.read<Session>();
    if (_step == _Step.agent) {
      if (session.agentHasPassword) {
        if (_password.text.isEmpty) throw 'Escreva a sua senha.';
      } else {
        checkNewPassword(_password.text, _confirm.text);
      }
      await session.openAgentSession(_password.text);
      return;
    }
    if (_step == _Step.code && _code.text.length == 6) {
      await session.verifyOtp(_role, _sentTo!, _code.text);
      // Número reservado: falta só a senha.
      if (session.agentTicket != null && mounted) {
        _waitTimer?.cancel();
        setState(() {
          _step = _Step.agent;
          _password.clear();
          _confirm.clear();
        });
        return;
      }
    } else if (_step == _Step.password || _passwordToo) {
      if (_password.text.isEmpty) {
        throw _step == _Step.code
            ? 'Escreva o código de 6 dígitos ou a sua senha.'
            : 'Escreva a sua senha.';
      }
      await session.loginWithPassword(_role, _sentTo!, _password.text);
    } else {
      throw 'O código tem 6 dígitos.';
    }
    _waitTimer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final account = _isDriver ? 'motorista' : 'passageiro';
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: BazaLogo(size: 44),
              ),
              const SizedBox(height: 6),
              const Text(
                '$appFullName · $appSlogan',
                style: TextStyle(
                  color: BazaColors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                _isDriver ? 'Conduza com o Bazá' : 'Vamos bazar?',
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Entre ou crie a sua conta de $account.',
                style: const TextStyle(color: BazaColors.muted, fontSize: 16),
              ),
              const SizedBox(height: 22),
              ...switch (_step) {
                _Step.phone => _phoneStep(),
                _Step.code => _codeStep(),
                _Step.password => _passwordStep(),
                _Step.agent => _agentStep(),
              },
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _phoneStep() => [
    const Text('Tipo de conta', style: TextStyle(fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    SegmentedButton<String>(
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: BazaColors.ink,
        selectedForegroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      segments: const [
        ButtonSegment(
          value: 'passenger',
          label: Text('Passageiro'),
          icon: Icon(Icons.hail),
        ),
        ButtonSegment(
          value: 'driver',
          label: Text('Motorista'),
          icon: Icon(Icons.local_taxi),
        ),
      ],
      selected: {_role},
      onSelectionChanged: (s) => setState(() => _role = s.first),
    ),
    const SizedBox(height: 20),
    TextField(
      controller: _phone,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submitKey.currentState?.trigger(),
      keyboardType: TextInputType.phone,
      autofillHints: const [AutofillHints.telephoneNumber],
      inputFormatters: const [PhoneInputFormatter()],
      decoration: const InputDecoration(
        labelText: 'Número de telefone',
        hintText: '923 456 789',
        prefixText: '+244  ',
      ),
    ),
    const SizedBox(height: 8),
    const Text(
      'Se ainda não tiver conta, confirmamos o número por SMS e cria-a a seguir, com a sua senha.',
      style: TextStyle(color: BazaColors.muted),
    ),
    const SizedBox(height: 20),
    AsyncButton(key: _submitKey, label: 'Continuar', onPressed: _start),
    const SizedBox(height: 14),
    const LegalLinks(prefix: 'Ao continuar, aceita os'),
  ];

  Widget _who() => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(
      '${_isDriver ? 'Conta de motorista' : 'Conta de passageiro'} · $_sentTo',
      style: const TextStyle(color: BazaColors.muted),
    ),
  );

  Widget _otherNumber() =>
      TextButton(onPressed: _restart, child: const Text('Usar outro número'));

  List<Widget> _codeStep() => [
    const Text(
      'Escreva o código que enviámos por SMS',
      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
    _who(),
    if (_devCode != null)
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          'Modo de desenvolvimento — código: $_devCode',
          style: const TextStyle(color: BazaColors.muted),
        ),
      ),
    const SizedBox(height: 16),
    TextField(
      controller: _code,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submitKey.currentState?.trigger(),
      autofocus: true,
      keyboardType: TextInputType.number,
      autofillHints: const [AutofillHints.oneTimeCode],
      maxLength: 6,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: const TextStyle(
        fontSize: 26,
        letterSpacing: 10,
        fontWeight: FontWeight.w700,
      ),
      decoration: const InputDecoration(hintText: '······', counterText: ''),
    ),
    if (_passwordToo) ...[
      const SizedBox(height: 16),
      const Text(
        'Ou entre com a sua senha',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 10),
      PasswordField(
        controller: _password,
        onSubmitted: () => _submitKey.currentState?.trigger(),
      ),
    ] else if (_canUsePassword) ...[
      const SizedBox(height: 12),
      Row(
        children: [
          const Expanded(
            child: Text(
              'Não tem o telefone consigo?',
              style: TextStyle(color: BazaColors.muted),
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _passwordToo = true),
            child: const Text('Entrar com a senha'),
          ),
        ],
      ),
    ],
    const SizedBox(height: 20),
    AsyncButton(key: _submitKey, label: 'Entrar', onPressed: _enter),
    const SizedBox(height: 8),
    _otherNumber(),
  ];

  /// Senha de um número reservado. O ecrã é igual ao de qualquer conta: nada
  /// aqui mostra de que tipo de conta se trata.
  List<Widget> _agentStep() {
    final has = context.read<Session>().agentHasPassword;
    return [
      Text(
        has ? 'Escreva a sua senha' : 'Crie a sua senha',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          '$_sentTo',
          style: const TextStyle(color: BazaColors.muted),
        ),
      ),
      const SizedBox(height: 16),
      PasswordField(
        controller: _password,
        autofocus: true,
        isNew: !has,
        action: has ? TextInputAction.done : TextInputAction.next,
        helper: has ? null : 'Pelo menos 6 caracteres.',
        onSubmitted: has ? () => _submitKey.currentState?.trigger() : null,
      ),
      if (!has) ...[
        const SizedBox(height: 14),
        PasswordField(
          controller: _confirm,
          label: 'Repita a senha',
          isNew: true,
          onSubmitted: () => _submitKey.currentState?.trigger(),
        ),
      ],
      const SizedBox(height: 20),
      AsyncButton(key: _submitKey, label: 'Entrar', onPressed: _enter),
      const SizedBox(height: 8),
      TextButton(
        onPressed: () {
          context.read<Session>().cancelAgentLogin();
          _restart();
        },
        child: const Text('Usar outro número'),
      ),
    ];
  }

  List<Widget> _passwordStep() => [
    const Text(
      'Escreva a sua senha',
      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
    _who(),
    if (_reason == 'sms_failed')
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          'Não foi possível enviar o código por SMS neste momento.',
          style: TextStyle(color: BazaColors.muted),
        ),
      ),
    const SizedBox(height: 16),
    PasswordField(
      controller: _password,
      autofocus: true,
      onSubmitted: () => _submitKey.currentState?.trigger(),
    ),
    const SizedBox(height: 20),
    AsyncButton(key: _submitKey, label: 'Entrar', onPressed: _enter),
    const SizedBox(height: 8),
    _otherNumber(),
    const Text(
      'Esqueceu a senha? Contacte o suporte do Bazá.',
      textAlign: TextAlign.center,
      style: TextStyle(color: BazaColors.muted, fontSize: 13),
    ),
  ];
}
