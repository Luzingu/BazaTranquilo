import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../screens/chat_screen.dart';
import '../state/call_state.dart';
import '../state/ride_state.dart';
import '../state/session.dart';

/// Contactar a outra pessoa da corrida: mensagem (chat) ou chamada.
class ContactBar extends StatelessWidget {
  const ContactBar({super.key, required this.ride});
  final Ride ride;

  @override
  Widget build(BuildContext context) {
    final rides = context.watch<RideState>();
    final call = context.read<CallState>();
    final iAmDriver = rides.role == AppMode.driver;
    final other = iAmDriver ? ride.passenger : ride.driver;
    if (other == null) return const SizedBox.shrink();
    final phone = other.phone;
    final unread = rides.unreadMessages;
    final who = iAmDriver ? 'passageiro' : 'motorista';

    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: BazaColors.ink,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(46),
            ),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => MultiProvider(
                  providers: [
                    ChangeNotifierProvider.value(value: rides),
                    ChangeNotifierProvider.value(value: call),
                  ],
                  child: ChatScreen(
                    ride: ride,
                    other: other,
                    iAmDriver: iAmDriver,
                  ),
                ),
              ),
            ),
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: const Icon(Icons.chat_bubble_outline, size: 20),
            ),
            label: FittedBox(
              child: Text(unread > 0 ? 'Mensagem nova' : 'Mensagem'),
            ),
          ),
        ),
        const SizedBox(width: 10),
        // Chamada de voz pela internet, dentro do app: o número não é mostrado.
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
            ),
            onPressed: () => call.call(ride),
            icon: const Icon(Icons.call_outlined, size: 20),
            label: FittedBox(child: Text('Ligar ao $who')),
          ),
        ),
        // Alternativa quando a internet está fraca: chamada normal de telemóvel.
        if (phone != null) ...[
          const SizedBox(width: 6),
          IconButton.outlined(
            tooltip: 'Ligar pelo telefone (mostra o número)',
            onPressed: () async {
              final ok = await launchUrl(Uri(scheme: 'tel', path: phone))
                  .catchError((_) => false);
              if (!ok && context.mounted)
                showError(
                  context,
                  'Não foi possível abrir o telefone. Número: $phone',
                );
            },
            icon: const Icon(Icons.dialpad, size: 20),
          ),
        ],
      ],
    );
  }
}
