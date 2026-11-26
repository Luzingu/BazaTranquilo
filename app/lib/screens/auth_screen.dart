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

/// Entrada no app: por defeito entra-se como passageiro; o botão "Sou
/// motorista" (ou "Sou passageiro") no cartão do topo troca, e o app lembra-se
/// da escolha neste aparelho. O tipo fica sempre à vista num cartão com cor
/// própria (amarelo para passageiro, escuro para motorista). Cada número só tem
/// um tipo de conta: se o número for do outro tipo, o app pergunta se quer
/// entrar nesse.
///
/// Escrito o número, o servidor
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

  /// Por onde foi o código, como o servidor o diz ("SMS", "WhatsApp"…).
  String _via = 'SMS';

  /// Tempo de espera pelo SMS antes de se pedir a senha a quem a tem.
  static const _codeWait = Duration(seconds: 60);

  // Cada número tem um só tipo de conta; o escolhido aqui decide em qual se
  // entra (ou que tipo se cria). Por defeito, passageiro.
  String _role = 'passenger';

  /// A escolha guardada já foi lida (evita mostrar passageiro e saltar logo
  /// para motorista).
  bool _roleLoaded = false;
  static const _storage = FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    _loadRole();
  }

  /// A escolha da vez anterior neste aparelho; sem nenhuma (ou se o
  /// armazenamento falhar), fica passageiro.
  Future<void> _loadRole() async {
    String? saved;
    try {
      saved = await _storage.read(key: 'lastRole');
    } catch (_) {
      saved = null;
    }
    if (!mounted) return;
    setState(() {
      if (saved == 'passenger' || saved == 'driver') _role = saved!;
      _roleLoaded = true;
    });
  }

  void _chooseRole(String role) {
    clearError(context);
    setState(() => _role = role);
    _storage.write(key: 'lastRole', value: role);
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
      _via = res['via'] as String? ?? _via;
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
        // O conteúdo em cima e, no passo do número, os Termos num rodapé:
        // em ecrãs altos ficam no fundo; em ecrãs pequenos (ou com o teclado
        // aberto) vêm logo a seguir ao botão e deslizam com o resto.
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
              sliver: SliverToBoxAdapter(child: _content()),
            ),
            SliverFillRemaining(
              hasScrollBody: false,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
                  child: _roleLoaded && _step == _Step.phone
                      ? const LegalLinks(
                          prefix: 'Ao continuar, aceita os',
                          center: true,
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Align(alignment: Alignment.centerLeft, child: BazaLogo(size: 44)),
      const SizedBox(height: 6),
      const Text(
        '$appFullName · $appSlogan',
        style: TextStyle(color: BazaColors.muted, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 24),
      if (!_roleLoaded)
        const SizedBox.shrink()
      else ...[
        _RoleBanner(
          driver: _isDriver,
          // Só se troca antes de escrever o número; depois, "Usar outro número".
          onSwitch: _step == _Step.phone
              ? () => _chooseRole(_isDriver ? 'passenger' : 'driver')
              : null,
        ),
        const SizedBox(height: 22),
        ..._stepWidgets(),
      ],
    ],
  );

  List<Widget> _stepWidgets() => [
    ...switch (_step) {
      _Step.phone => _phoneStep(),
      _Step.code => _codeStep(),
      _Step.password => _passwordStep(),
      _Step.agent => _agentStep(),
      _Step.signup => _signupStep(),
    },
  ];

  List<Widget> _phoneStep() => [
    PhoneField(
      controller: _phone,
      autofill: true,
      onSubmitted: () => _submitKey.currentState?.trigger(),
    ),
    const SizedBox(height: 8),
    const Text(
      'Se ainda não tiver conta, confirmamos o número por SMS e cria-a a seguir, com a sua senha.',
      style: TextStyle(color: BazaColors.muted),
    ),
    const SizedBox(height: 20),
    AsyncButton(key: _submitKey, label: 'Continuar', onPressed: _start),
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
    Text(
      'Escreva o código que enviámos por $_via',
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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

/// O tipo de conta escolhido, sempre à vista nos passos seguintes.
class _RoleBanner extends StatelessWidget {
  const _RoleBanner({required this.driver, this.onSwitch});
  final bool driver;

  /// Troca para o outro tipo de conta (só no passo do número).
  final VoidCallback? onSwitch;

  @override
  Widget build(BuildContext context) {
    final fg = driver ? Colors.white : BazaColors.ink;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: driver ? BazaColors.ink : BazaColors.yellow,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
            ],
          ),
          // Linha própria, para caber em qualquer ecrã. Botão com o ícone do
          // outro tipo: diz o que faz sem ser preciso perceber "trocar".
          if (onSwitch != null) ...[
            const SizedBox(height: 10),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 6,
              children: [
                Text(
                  driver ? 'Vai viajar?' : 'Vai conduzir?',
                  style: TextStyle(color: fg, fontWeight: FontWeight.w600),
                ),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: driver ? BazaColors.yellow : Colors.white,
                    foregroundColor: BazaColors.ink,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    // O tema dá aos botões a largura toda; aqui fica do tamanho do texto.
                    minimumSize: const Size(0, 44),
                  ),
                  onPressed: onSwitch,
                  icon: Icon(driver ? Icons.hail : Icons.local_taxi, size: 22),
                  label: Text(
                    driver ? 'Sou passageiro' : 'Sou motorista',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
