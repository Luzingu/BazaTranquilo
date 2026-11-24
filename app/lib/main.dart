import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/theme.dart';
import 'core/config.dart';
import 'screens/agent_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/home_shell.dart';
import 'screens/splash_screen.dart';
import 'screens/vehicle_screen.dart';
import 'services/notifier.dart';
import 'state/session.dart';
import 'widgets/common.dart';
import 'widgets/desktop_frame.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // O app é pensado para o telemóvel ao alto (mapa e painéis em baixo); deitado,
  // os ecrãs ficam sem espaço. Na web o browser decide.
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  Notifier.instance.init();
  loadMapConfig();
  runApp(
    ChangeNotifierProvider(
      create: (_) => Session()..init(),
      child: const BazaApp(),
    ),
  );
}

class BazaApp extends StatelessWidget {
  const BazaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appFullName,
      debugShowCheckedModeBanner: false,
      theme: bazaTheme(),
      // No computador, o app aparece numa janela centrada (ver DesktopFrame).
      builder: (context, child) =>
          DesktopFrame(child: child ?? const SizedBox()),
      home: const _Root(),
    );
  }
}

class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  /// O ecrã de arranque fica pelo menos este tempo, para a animação da marca se
  /// ver mesmo quando a sessão carrega num instante.
  static const _minSplash = Duration(milliseconds: 1800);
  bool _splashDone = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(_minSplash, () {
      if (mounted) setState(() => _splashDone = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    if (session.loading || !_splashDone) return const SplashScreen();
    if (session.initError != null) {
      return SplashScreen(
        error: session.initError,
        onRetry: session.retry,
        onLogout: session.logout,
      );
    }
    final user = session.user;
    // Agente de um posto policial: área própria, sem nada do resto do app.
    if (session.agent != null) return const AgentHome();
    if (user == null) return const AuthScreen();
    // Conta nova (ou criada antes de haver senha): escolhe a senha primeiro.
    if (!user.hasPassword) return const PasswordSetupScreen();
    if (user.name.isEmpty) return const OnboardingScreen();
    if (user.isDriver && !user.driverProfileComplete)
      return const VehicleScreen(onboarding: true);
    // A chave garante estado novo quando outra conta entra.
    return HomeShell(key: ValueKey(user.id));
  }
}

/// Último passo da criação de conta por telefone: o nome.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  /// A tecla Enter no último campo faz o mesmo que o botão principal.
  final _submitKey = GlobalKey<AsyncButtonState>();

  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.read<Session>();
    final isDriver = session.user?.isDriver ?? false;
    return Scaffold(
      appBar: AppBar(
        actions: [
          TextButton(onPressed: session.logout, child: const Text('Sair')),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Como se chama?',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              isDriver
                  ? 'Os passageiros vão ver este nome.'
                  : 'O motorista vai ver este nome.',
              style: const TextStyle(color: BazaColors.muted),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _name,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submitKey.currentState?.trigger(),
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nome'),
            ),
            const SizedBox(height: 20),
            AsyncButton(
              key: _submitKey,
              label: 'Continuar',
              onPressed: () async {
                final name = _name.text.trim();
                if (name.length < 2) throw 'Escreva o seu nome.';
                await session.updateProfile(name: name);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Passo da criação de conta: a senha. Serve para entrar com o número e a
/// senha quando o código SMS está desligado ou não chega.
class PasswordSetupScreen extends StatefulWidget {
  const PasswordSetupScreen({super.key});

  @override
  State<PasswordSetupScreen> createState() => _PasswordSetupScreenState();
}

class _PasswordSetupScreenState extends State<PasswordSetupScreen> {
  final _submitKey = GlobalKey<AsyncButtonState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.read<Session>();
    return Scaffold(
      appBar: AppBar(
        actions: [
          TextButton(onPressed: session.logout, child: const Text('Sair')),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Crie a sua senha',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              session.phoneRecovered
                  ? 'Número confirmado. Esta conta tinha sido criada sem o SMS chegar, por isso, por segurança, escolha uma senha nova.'
                  : 'Com o seu número e esta senha entra no Bazá mesmo quando o código por SMS não chega.',
              style: const TextStyle(color: BazaColors.muted),
            ),
            const SizedBox(height: 24),
            PasswordField(
              controller: _password,
              isNew: true,
              autofocus: true,
              action: TextInputAction.next,
              helper: 'Pelo menos 6 caracteres.',
            ),
            const SizedBox(height: 14),
            PasswordField(
              controller: _confirm,
              label: 'Repita a senha',
              isNew: true,
              onSubmitted: () => _submitKey.currentState?.trigger(),
            ),
            const SizedBox(height: 20),
            AsyncButton(
              key: _submitKey,
              label: 'Continuar',
              onPressed: () async {
                checkNewPassword(_password.text, _confirm.text);
                await session.setPassword(_password.text);
              },
            ),
          ],
        ),
      ),
    );
  }
}
