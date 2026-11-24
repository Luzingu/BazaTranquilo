import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../state/session.dart';
import '../widgets/common.dart';
import '../widgets/phone_confirm.dart';
import '../widgets/profile_photo.dart';

/// "Os meus dados": foto, nome, email de contacto, telefone e contacto de emergência.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  /// A tecla Enter no último campo faz o mesmo que o botão principal.
  final _submitKey = GlobalKey<AsyncButtonState>();

  late final TextEditingController _name, _email;

  @override
  void initState() {
    super.initState();
    final user = context.read<Session>().user!;
    _name = TextEditingController(text: user.name);
    _email = TextEditingController(text: user.email);
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final session = context.read<Session>();
    final messenger = ScaffoldMessenger.of(context);
    final name = _name.text.trim();
    final email = _email.text.trim();
    if (name.length < 2) throw 'Escreva o seu nome.';
    if (email.isNotEmpty && !email.contains('@'))
      throw 'Escreva um email válido.';
    if (email.isEmpty && session.user!.email != null)
      throw 'O email não pode ficar vazio.';
    await session.updateProfile(
      name: name,
      email: email.isEmpty ? null : email,
    );
    messenger.showSnackBar(const SnackBar(content: Text('Dados guardados.')));
  }

  Future<void> _sheet(Widget child) => showModalBottomSheet<void>(
    isDismissible: false,
    context: context,
    backgroundColor: Colors.white,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => child,
  );

  /// Elimina a conta, depois de o utilizador escrever ELIMINAR para confirmar.
  Future<void> _deleteAccount() async {
    final session = context.read<Session>();
    final typed = TextEditingController();
    final confirmed = await showDialog<bool>(
      barrierDismissible: false,
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar a conta?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'São apagados de imediato o seu nome, telefone, fotografia, documentos, locais guardados e mensagens. '
              'Não é possível recuperar a conta.\n\nPara confirmar, escreva ELIMINAR.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: typed,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(hintText: 'ELIMINAR'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Manter a conta'),
          ),
          ValueListenableBuilder(
            valueListenable: typed,
            builder: (context, value, _) => TextButton(
              style: TextButton.styleFrom(foregroundColor: BazaColors.red),
              onPressed: value.text.trim().toUpperCase() == 'ELIMINAR'
                  ? () => Navigator.pop(context, true)
                  : null,
              child: const Text('Eliminar'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await session.deleteAccount();
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<Session>().user;
    if (user == null) return const SizedBox.shrink(); // sessão terminada
    const section = TextStyle(fontSize: 17, fontWeight: FontWeight.w800);

    return Scaffold(
      appBar: AppBar(title: const Text('Os meus dados')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Center(
              child: Column(
                children: [
                  Avatar(name: user.name, photoUrl: user.photoUrl, radius: 48),
                  TextButton.icon(
                    onPressed: () => changeProfilePhoto(context),
                    icon: const Icon(Icons.photo_camera_outlined, size: 20),
                    label: Text(
                      user.photoUrl == null ? 'Adicionar foto' : 'Alterar foto',
                    ),
                  ),
                  Text(
                    user.isDriver
                        ? 'Conta de motorista'
                        : 'Conta de passageiro',
                    style: const TextStyle(color: BazaColors.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _name,
              textInputAction: TextInputAction.next,
              textCapitalization: TextCapitalization.words,
              autofillHints: const [AutofillHints.name],
              decoration: const InputDecoration(labelText: 'Nome'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _email,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submitKey.currentState?.trigger(),
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                labelText: 'Email (opcional)',
                helperText:
                    'Só para receber avisos. Entra-se sempre com o telefone.',
              ),
            ),
            const SizedBox(height: 16),
            AsyncButton(key: _submitKey, label: 'Guardar', onPressed: _save),
            const SizedBox(height: 28),
            const Text('Telefone', style: section),
            _ActionRow(
              icon: Icons.phone_iphone,
              value: user.phone ?? 'Sem número associado',
              action: user.phone == null ? 'Adicionar' : 'Alterar',
              onTap: () => _sheet(const _PhoneSheet()),
            ),
            const PhoneUnconfirmedTile(),
            const SizedBox(height: 20),
            const Text('Senha', style: section),
            _ActionRow(
              icon: Icons.lock_outline,
              value: user.hasPassword
                  ? 'Pedida ao entrar quando o código SMS não está disponível.'
                  : 'Ainda não definiu uma senha.',
              action: user.hasPassword ? 'Alterar' : 'Definir',
              onTap: () => _sheet(const _PasswordSheet()),
            ),
            const SizedBox(height: 20),
            const Text('Contacto de emergência', style: section),
            _ActionRow(
              icon: Icons.health_and_safety_outlined,
              value: user.emergencyPhone == null
                  ? 'Alguém de confiança a quem enviar a sua viagem numa emergência (botão SOS).'
                  : '${user.emergencyName ?? ''} · ${user.emergencyPhone}',
              action: user.emergencyPhone == null ? 'Definir' : 'Alterar',
              onTap: () => _sheet(const _EmergencySheet()),
            ),
            const SizedBox(height: 20),
            const Text('Privacidade', style: section),
            const LegalLinks(),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: BazaColors.red),
                onPressed: _deleteAccount,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Eliminar conta'),
              ),
            ),
            if (user.isDriver) ...[
              const SizedBox(height: 20),
              const Text(
                'A carta de condução e a viatura alteram-se em "Carta e viatura", no menu.',
                style: TextStyle(color: BazaColors.muted, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.value,
    required this.action,
    required this.onTap,
  });
  final IconData icon;
  final String value;
  final String? action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      children: [
        Icon(icon, color: BazaColors.muted),
        const SizedBox(width: 12),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 15))),
        if (action != null) TextButton(onPressed: onTap, child: Text(action!)),
      ],
    ),
  );
}

Widget _sheetBody(BuildContext context, String title, List<Widget> children) =>
    Padding(
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
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    );

/// Alterar o telefone: o número novo tem de ser confirmado por SMS.
class _PhoneSheet extends StatefulWidget {
  const _PhoneSheet();

  @override
  State<_PhoneSheet> createState() => _PhoneSheetState();
}

class _PhoneSheetState extends State<_PhoneSheet> {
  /// A tecla Enter no último campo faz o mesmo que o botão principal.
  final _submitKey = GlobalKey<AsyncButtonState>();

  final _phone = TextEditingController();
  final _code = TextEditingController();
  String? _pending; // número à espera de confirmação
  String? _devCode;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _request() async {
    final phone = _phone.text.replaceAll(' ', '');
    if (phone.length < 9) throw 'Escreva o novo número de telefone.';
    final devCode = await context.read<Session>().requestPhoneChange(phone);
    if (mounted) {
      setState(() {
        _pending = phone;
        _devCode = devCode;
      });
    }
  }

  Future<void> _confirm() async {
    if (_code.text.length != 6) throw 'O código tem 6 dígitos.';
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await context.read<Session>().confirmPhoneChange(_pending!, _code.text);
    navigator.pop();
    messenger.showSnackBar(
      const SnackBar(content: Text('Número de telefone alterado.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_pending == null) {
      return _sheetBody(context, 'Novo número de telefone', [
        TextField(
          controller: _phone,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submitKey.currentState?.trigger(),
          autofocus: true,
          keyboardType: TextInputType.phone,
          inputFormatters: const [PhoneInputFormatter()],
          decoration: const InputDecoration(
            labelText: 'Número de telefone',
            hintText: '923 456 789',
            prefixText: '+244  ',
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Enviamos um código por SMS para confirmar o número novo.',
          style: TextStyle(color: BazaColors.muted),
        ),
        const SizedBox(height: 16),
        AsyncButton(
          key: _submitKey,
          label: 'Receber código',
          onPressed: _request,
        ),
      ]);
    }
    return _sheetBody(context, 'Confirmar número', [
      Text('Código enviado para $_pending', textAlign: TextAlign.center),
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
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submitKey.currentState?.trigger(),
        autofocus: true,
        keyboardType: TextInputType.number,
        maxLength: 6,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(
          fontSize: 24,
          letterSpacing: 8,
          fontWeight: FontWeight.w700,
        ),
        decoration: const InputDecoration(hintText: '······', counterText: ''),
      ),
      const SizedBox(height: 16),
      AsyncButton(key: _submitKey, label: 'Confirmar', onPressed: _confirm),
    ]);
  }
}

/// Definir, alterar ou remover o contacto de emergência.
class _EmergencySheet extends StatefulWidget {
  const _EmergencySheet();

  @override
  State<_EmergencySheet> createState() => _EmergencySheetState();
}

class _EmergencySheetState extends State<_EmergencySheet> {
  final _submitKey = GlobalKey<AsyncButtonState>();
  late final TextEditingController _name, _phone;

  @override
  void initState() {
    super.initState();
    final user = context.read<Session>().user;
    _name = TextEditingController(text: user?.emergencyName);
    _phone = TextEditingController(
      text: user?.emergencyPhone?.replaceFirst('+244', ''),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim(), phone = _phone.text.replaceAll(' ', '');
    if (name.isEmpty) throw 'Escreva o nome do contacto.';
    if (phone.length < 9) throw 'Escreva o número de telefone do contacto.';
    final navigator = Navigator.of(context);
    await context.read<Session>().setEmergencyContact(name: name, phone: phone);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.read<Session>();
    final hasContact = session.user?.emergencyPhone != null;
    return _sheetBody(context, 'Contacto de emergência', [
      const Text(
        'Numa emergência, o botão SOS deixa-o enviar a sua viagem a esta pessoa por SMS.',
        textAlign: TextAlign.center,
        style: TextStyle(color: BazaColors.muted),
      ),
      const SizedBox(height: 14),
      TextField(
        controller: _name,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(
          labelText: 'Nome',
          hintText: 'Ex.: Mãe',
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _phone,
        keyboardType: TextInputType.phone,
        textInputAction: TextInputAction.done,
        inputFormatters: const [PhoneInputFormatter()],
        onSubmitted: (_) => _submitKey.currentState?.trigger(),
        decoration: const InputDecoration(
          labelText: 'Telefone',
          hintText: '923 456 789',
          prefixText: '+244  ',
        ),
      ),
      const SizedBox(height: 16),
      AsyncButton(key: _submitKey, label: 'Guardar', onPressed: _save),
      if (hasContact)
        TextButton(
          onPressed: () async {
            final navigator = Navigator.of(context);
            try {
              await session.setEmergencyContact();
              navigator.pop();
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
          },
          child: const Text('Remover contacto'),
        ),
    ]);
  }
}

/// Mudar a senha: confirma-se a actual e escolhe-se a nova.
class _PasswordSheet extends StatefulWidget {
  const _PasswordSheet();

  @override
  State<_PasswordSheet> createState() => _PasswordSheetState();
}

class _PasswordSheetState extends State<_PasswordSheet> {
  final _submitKey = GlobalKey<AsyncButtonState>();
  final _current = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _current.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.read<Session>();
    final has = session.user?.hasPassword ?? false;
    return _sheetBody(context, has ? 'Alterar a senha' : 'Definir a senha', [
      if (has) ...[
        PasswordField(
          controller: _current,
          label: 'Senha actual',
          autofocus: true,
          action: TextInputAction.next,
          helper: 'Esqueceu-a? Peça ao suporte do Bazá para a repor.',
        ),
        const SizedBox(height: 12),
      ],
      PasswordField(
        controller: _password,
        label: 'Senha nova',
        isNew: true,
        autofocus: !has,
        action: TextInputAction.next,
        helper: 'Pelo menos 6 caracteres.',
      ),
      const SizedBox(height: 12),
      PasswordField(
        controller: _confirm,
        label: 'Repita a senha nova',
        isNew: true,
        onSubmitted: () => _submitKey.currentState?.trigger(),
      ),
      const SizedBox(height: 16),
      AsyncButton(
        key: _submitKey,
        label: 'Guardar',
        onPressed: () async {
          if (has && _current.text.isEmpty) throw 'Escreva a senha actual.';
          checkNewPassword(_password.text, _confirm.text);
          await session.setPassword(
            _password.text,
            current: has ? _current.text : null,
          );
          if (context.mounted) Navigator.pop(context);
        },
      ),
    ]);
  }
}
