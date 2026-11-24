import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/theme.dart';
import '../state/session.dart';
import '../widgets/common.dart';

/// "Frota": o motorista vê a empresa a que pertence, junta-se a uma com o
/// código que ela lhe deu, ou sai e volta a ser independente.
class FleetScreen extends StatefulWidget {
  const FleetScreen({super.key});

  @override
  State<FleetScreen> createState() => _FleetScreenState();
}

class _FleetScreenState extends State<FleetScreen> {
  final _submitKey = GlobalKey<AsyncButtonState>();
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final session = context.read<Session>();
    final code = _code.text.trim();
    if (code.length < 4) throw 'Escreva o código que a frota lhe deu.';
    final res = await session.api.post('/driver/fleet', {'code': code});
    session.setUser(User.fromJson(res['user'] as Map<String, dynamic>));
    _code.clear();
  }

  Future<void> _leave(String fleetName) async {
    final session = context.read<Session>();
    final confirmed = await showDialog<bool>(
      barrierDismissible: false,
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Sair da frota $fleetName?'),
        content: const Text(
          'Passa a ser motorista independente. A sua conta e os seus documentos mantêm-se.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Não'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sair da frota'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final res = await session.api.delete('/driver/fleet');
    session.setUser(User.fromJson(res['user'] as Map<String, dynamic>));
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<Session>().user;
    if (user == null) return const SizedBox.shrink(); // sessão terminada
    final fleet = user.fleetName;
    return Scaffold(
      appBar: AppBar(title: const Text('Frota')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: fleet != null
              ? [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: BazaColors.surface,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.apartment_outlined, size: 32),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Pertence à frota',
                                style: TextStyle(color: BazaColors.muted),
                              ),
                              Text(
                                fleet,
                                style: const TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'A frota acompanha a sua actividade no painel dela: se está online, onde está e as corridas que faz.',
                    style: TextStyle(color: BazaColors.muted),
                  ),
                  const SizedBox(height: 24),
                  AsyncButton(
                    label: 'Sair da frota',
                    outlined: true,
                    danger: true,
                    onPressed: () => _leave(fleet),
                  ),
                ]
              : [
                  const Text(
                    'Motorista independente',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Se trabalha para uma empresa parceira do Bazá, introduza o código que ela lhe deu para se juntar à frota.',
                    style: TextStyle(color: BazaColors.muted, fontSize: 15),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _code,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    maxLength: 12,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submitKey.currentState?.trigger(),
                    style: const TextStyle(
                      fontSize: 22,
                      letterSpacing: 4,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Código da frota',
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 16),
                  AsyncButton(
                    key: _submitKey,
                    label: 'Juntar-me à frota',
                    onPressed: _join,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Ao juntar-se, a frota passa a ver a sua actividade (se está online, a sua posição e as suas corridas).',
                    style: TextStyle(color: BazaColors.muted, fontSize: 13),
                  ),
                ],
        ),
      ),
    );
  }
}
