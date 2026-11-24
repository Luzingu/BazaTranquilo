import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../state/session.dart';
import '../widgets/common.dart';
import 'splash_screen.dart';

/// Entrada no app: primeiro escolhe-se, em grande, se vai viajar ou conduzir
/// (o app lembra-se da escolha neste aparelho); depois escreve-se o número. O
/// tipo escolhido fica sempre à vista num cartão com cor própria (amarelo para
/// passageiro, escuro para motorista). Cada número só tem um tipo de conta: se
/// o número for do outro tipo, o app pergunta se quer entrar nesse.
///
/// Escrito o número, O servidor
/// decide o passo seguinte, conforme o que está definido no painel: código SMS
/// ou senha. A senha é pedida automaticamente quando o código está desligado,
/// quando o envio do SMS falha, ou quando o código não chega. Se o SMS falhar a
/// quem cria conta, a conta cria-se na mesma (só com a senha) e o número fica
/// por confirmar: o app pede o código mais tarde (widgets/phone_confirm.dart).
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

enum _Step { phone, code, password, agent, signup }

class _AuthScreenState extends State<AuthScreen> {
  /// A tecla Enter no último campo faz o mesmo que o botão principal.
  final _submitKey = GlobalKey<AsyncButtonState>();

  /// Tempo de espera pelo SMS antes de se pedir a senha a quem a tem.
  static const _codeWait = Duration(seconds: 60);

  // Cada número tem um só tipo de conta; o escolhido aqui decide em qual se
  // entra (ou que tipo se cria).
  String _role = 'passenger';

  /// Já escolheu (agora ou numa vez anterior, neste aparelho) se viaja ou conduz.
  bool _roleChosen = false;
  bool _roleLoaded = false;
  static const _storage = FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    _loadRole();
  }

  /// A escolha da vez anterior neste aparelho. Se o armazenamento falhar,
  /// mostra-se a escolha (nunca um ecrã vazio).
  Future<void> _loadRole() async {
    String? saved;
    try {
      saved = await _storage.read(key: 'lastRole');
    } catch (_) {
      saved = null;
    }
    if (!mounted) return;
    setState(() {
      if (saved == 'passenger' || saved == 'driver') {
        _role = saved!;
        _roleChosen = true;
      }
      _roleLoaded = true;
    });
  }

  void _chooseRole(String role) {
    clearError(context);
    setState(() {
      _role = role;
      _roleChosen = true;
    });
    _storage.write(key: 'lastRole', value: role);
  }

  /// Volta ao ecrã de escolha (botão "Trocar").
  void _changeRole() {
    _restart();
    setState(() => _roleChosen = false);
  }

  _Step _step = _Step.phone;
  String? _sentTo; // número a que o código foi enviado / de quem é a senha
  String? _devCode;

  /// Bilhete para criar a conta sem o código (o SMS falhou).
  String? _signupTicket;

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
      _signupTicket = null;
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
    final Map<String, dynamic> res;
    try {
      res = await session.startLogin(_role, phone);
    } on ApiException catch (e) {
      final other = e.data['otherRole'];
      if (e.status != 409 || (other != 'passenger' && other != 'driver')) {
        rethrow;
      }
      // O número é do outro tipo de conta: oferece a troca.
      if (!mounted || !await _offerRole(other as String)) return;
      _chooseRole(other);
      return _start();
    }
    if (!mounted) return;
    _waitTimer?.cancel();
    final byPassword = res['method'] == 'password';
    final signup = res['method'] == 'signup';
    setState(() {
      _sentTo = phone;
      _step = signup
          ? _Step.signup
          : byPassword
          ? _Step.password
          : _Step.code;
      _signupTicket = res['signupTicket'] as String?;
      _confirm.clear();
      _reason = res['reason'] as String?;
      _devCode = res['devCode'] as String?;
      _canUsePassword = res['canUsePassword'] == true;
      _passwordToo = false;
      _code.clear();
      _password.clear();
    });
    if (!byPassword && !signup) _waitTimer = Timer(_codeWait, _codeIsLate);
  }

  /// "Este número está registado como motorista. Entrar como motorista?"
  Future<bool> _offerRole(String other) async {
    final driver = other == 'driver';
    final name = driver ? 'motorista' : 'passageiro';
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: Icon(driver ? Icons.local_taxi : Icons.hail, size: 36),
        title: Text('Este número é de $name'),
        content: Text(
          'O ${_phone.text} está registado como $name. Cada número só pode ter um tipo de conta.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Usar outro número'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Entrar como $name'),
          ),
        ],
      ),
    );
    return ok ?? false;
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
    if (_step == _Step.signup) {
      checkNewPassword(_password.text, _confirm.text);
      await session.signupWithoutCode(_signupTicket!, _password.text);
      return;
    }
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
              if (!_roleLoaded)
                const SizedBox.shrink()
              else if (!_roleChosen)
                ..._roleStep()
              else ...[
                _RoleBanner(
                  driver: _isDriver,
                  // Só se troca antes de escrever o número; depois, "Usar outro número".
                  onChange: _step == _Step.phone ? _changeRole : null,
                ),
                const SizedBox(height: 22),
                ..._stepWidgets(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _stepWidgets() => [
    ...switch (_step) {
      _Step.phone => _phoneStep(),
      _Step.code => _codeStep(),
      _Step.password => _passwordStep(),
      _Step.agent => _agentStep(),
      _Step.signup => _signupStep(),
    },
  ];

  /// Primeira vez neste aparelho: escolhe-se, em grande, se vai viajar ou conduzir.
  List<Widget> _roleStep() => [
    const Text(
      'Como vai usar o Bazá?',
      style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
    ),
    const SizedBox(height: 6),
    const Text(
      'Escolha uma opção. Cada número de telefone tem um só tipo de conta.',
      style: TextStyle(color: BazaColors.muted, fontSize: 16),
    ),
    const SizedBox(height: 22),
    _RoleCard(
      driver: false,
      title: 'Quero viajar',
      text: 'Peça táxi, moto ou carga e acompanhe o motorista no mapa.',
      onTap: () => _chooseRole('passenger'),
    ),
    const SizedBox(height: 14),
    _RoleCard(
      driver: true,
      title: 'Quero conduzir',
      text: 'Receba pedidos de corrida com a sua viatura.',
      onTap: () => _chooseRole('driver'),
    ),
    const SizedBox(height: 20),
    const LegalLinks(prefix: 'Ao continuar, aceita os'),
  ];

  List<Widget> _phoneStep() => [
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

  /// O SMS não saiu e é uma conta nova: cria-se só com a senha.
  List<Widget> _signupStep() => [
    Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7DB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BazaColors.yellow),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.sms_failed_outlined, color: BazaColors.ink),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Não conseguimos enviar o SMS agora. Não faz mal: crie a sua senha e entre já. Confirmamos o número mais tarde, quando o SMS voltar a funcionar.',
            ),
          ),
        ],
      ),
    ),
    const SizedBox(height: 16),
    const Text(
      'Crie a sua senha',
      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
    _who(),
    const SizedBox(height: 16),
    PasswordField(
      controller: _password,
      autofocus: true,
      isNew: true,
      action: TextInputAction.next,
      helper: 'Pelo menos 6 caracteres. É com ela que volta a entrar.',
    ),
    const SizedBox(height: 14),
    PasswordField(
      controller: _confirm,
      label: 'Repita a senha',
      isNew: true,
      onSubmitted: () => _submitKey.currentState?.trigger(),
    ),
    const SizedBox(height: 20),
    AsyncButton(key: _submitKey, label: 'Criar conta', onPressed: _enter),
    const SizedBox(height: 8),
    TextButton(
      onPressed: () async {
        try {
          await _start();
        } catch (e) {
          if (mounted) showError(context, e);
        }
      },
      child: const Text('Tentar enviar o SMS outra vez'),
    ),
    _otherNumber(),
  ];

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

/// Cartão grande da escolha inicial: amarelo para quem viaja, escuro para quem conduz.
class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.driver,
    required this.title,
    required this.text,
    required this.onTap,
  });
  final bool driver;
  final String title, text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = driver ? Colors.white : BazaColors.ink;
    return Semantics(
      button: true,
      label: title,
      child: Material(
        color: driver ? BazaColors.ink : BazaColors.yellow,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 14, 20),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: driver
                      ? Colors.white.withValues(alpha: 0.12)
                      : Colors.white.withValues(alpha: 0.55),
                  child: Icon(
                    driver ? Icons.local_taxi : Icons.hail,
                    size: 32,
                    color: driver ? BazaColors.yellow : BazaColors.ink,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: fg,
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        driver ? 'Conta de motorista' : 'Conta de passageiro',
                        style: TextStyle(
                          color: fg.withValues(alpha: 0.75),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(text, style: TextStyle(color: fg)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// O tipo de conta escolhido, sempre à vista nos passos seguintes.
class _RoleBanner extends StatelessWidget {
  const _RoleBanner({required this.driver, this.onChange});
  final bool driver;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    final fg = driver ? Colors.white : BazaColors.ink;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: driver ? BazaColors.ink : BazaColors.yellow,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(
            driver ? Icons.local_taxi : Icons.hail,
            size: 30,
            color: driver ? BazaColors.yellow : BazaColors.ink,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  driver ? 'Conduza com o Bazá' : 'Vamos bazar?',
                  style: TextStyle(
                    color: fg,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  driver
                      ? 'A entrar como motorista'
                      : 'A entrar como passageiro',
                  style: TextStyle(
                    color: fg.withValues(alpha: 0.8),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (onChange != null)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: fg),
              onPressed: onChange,
              child: const Text(
                'Trocar',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
