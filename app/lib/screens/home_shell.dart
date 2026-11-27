import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/servidores.dart';
import '../widgets/escolha_servidor.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../state/call_state.dart';
import '../state/ride_state.dart';
import '../state/session.dart';
import '../widgets/common.dart';
import '../widgets/phone_confirm.dart';
import '../widgets/profile_photo.dart';
import 'call_screen.dart';
import 'driver_account_screen.dart';
import 'intercity_screen.dart';
import 'driver_home.dart';
import 'contribute_screen.dart';
import 'favorites_screen.dart';
import 'fleet_screen.dart';
import 'garage_screen.dart';
import 'history_screen.dart';
import 'notices_screen.dart';
import 'passenger_home.dart';
import 'profile_screen.dart';
import 'saved_places_screen.dart';
import 'support_screen.dart';
import 'vehicle_screen.dart';
import 'wallet_screen.dart';

/// Ecrã principal: mapa do passageiro ou do motorista, com o menu lateral.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (context) => RideState(context.read<Session>())..load(),
        ),
        // Chamadas de voz no app entre passageiro e motorista.
        ChangeNotifierProvider(
          create: (context) =>
              CallState(context.read<Session>(), context.read<RideState>()),
        ),
      ],
      child: const _CallHost(
        child: NoticeHost(child: PhoneConfirmHost(child: _Shell())),
      ),
    );
  }
}

/// Abre o ecrã de chamada por cima de tudo quando começa uma chamada (feita ou
/// recebida) e fecha-o quando ela termina.
class _CallHost extends StatefulWidget {
  const _CallHost({required this.child});
  final Widget child;

  @override
  State<_CallHost> createState() => _CallHostState();
}

class _CallHostState extends State<_CallHost> {
  late final CallState _call = context.read<CallState>();
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _call.addListener(_sync);
  }

  @override
  void dispose() {
    _call.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    if (_call.phase != CallPhase.idle && !_open) {
      _open = true;
      navigator
          .push(
            MaterialPageRoute<void>(
              fullscreenDialog: true,
              settings: const RouteSettings(name: 'chamada'),
              builder: (_) => ChangeNotifierProvider.value(
                value: _call,
                child: const CallScreen(),
              ),
            ),
          )
          .whenComplete(() => _open = false);
    } else if (_call.phase == CallPhase.idle && _open) {
      // Fecha só o ecrã da chamada, esteja ele por cima do que estiver.
      navigator.popUntil((route) => route.settings.name != 'chamada');
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Shell extends StatelessWidget {
  const _Shell();

  @override
  Widget build(BuildContext context) {
    final isDriver = context.select<Session, bool>(
      (s) => s.user?.isDriver ?? false,
    );
    final loaded = context.select<RideState, bool>((r) => r.loaded);

    return Scaffold(
      endDrawer: const _Menu(),
      body: Stack(
        children: [
          if (!loaded)
            const Center(
              child: CircularProgressIndicator(color: BazaColors.ink),
            )
          else if (isDriver)
            const DriverHome()
          else
            const PassengerHome(),
          // Barra do topo: logótipo à esquerda, menu de navegação à direita.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Container(
                    height: 44,
                    padding: const EdgeInsets.fromLTRB(8, 0, 14, 0),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 8,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: const BazaLogo(size: 28),
                  ),
                  const Spacer(),
                  Builder(
                    builder: (context) => Material(
                      color: Colors.white,
                      elevation: 3,
                      shadowColor: Colors.black54,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => Scaffold.of(context).openEndDrawer(),
                        child: const SizedBox(
                          width: 44,
                          height: 44,
                          child: Icon(
                            Icons.menu,
                            color: BazaColors.ink,
                            semanticLabel: 'Menu',
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Menu extends StatelessWidget {
  const _Menu();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final rides = context.watch<RideState>();
    final user = session.user!;
    final onRide = rides.ride?.isActive ?? false;

    void open(Widget screen) {
      Navigator.of(context)
        ..pop()
        ..push(MaterialPageRoute(builder: (_) => screen));
    }

    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
              child: Row(
                children: [
                  Semantics(
                    button: true,
                    label: 'Alterar foto de perfil',
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => changeProfilePhoto(context),
                      child: Stack(
                        children: [
                          Avatar(
                            name: user.name,
                            photoUrl: user.photoUrl,
                            radius: 32,
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: BazaColors.ink,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                              ),
                              child: const Icon(
                                Icons.photo_camera,
                                size: 13,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          user.phone ?? user.email ?? '',
                          style: const TextStyle(color: BazaColors.muted),
                        ),
                        if (user.rating != null)
                          Row(
                            children: [
                              const Icon(
                                Icons.star_rounded,
                                size: 18,
                                color: BazaColors.yellow,
                              ),
                              Text(
                                user.rating!
                                    .toStringAsFixed(1)
                                    .replaceAll('.', ','),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                  // Atalho para editar os dados, junto ao nome.
                  IconButton.filledTonal(
                    tooltip: 'Editar os meus dados',
                    style: IconButton.styleFrom(
                      backgroundColor: BazaColors.surface,
                      foregroundColor: BazaColors.ink,
                    ),
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () => open(const ProfileScreen()),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Chip(
                  avatar: Icon(
                    user.isDriver ? Icons.local_taxi : Icons.hail,
                    size: 18,
                  ),
                  label: Text(
                    user.isDriver
                        ? 'Conta de motorista'
                        : 'Conta de passageiro',
                  ),
                  backgroundColor: BazaColors.surface,
                  side: BorderSide.none,
                ),
              ),
            ),
            // Conta criada sem o SMS chegar: confirmar o número a qualquer momento.
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: PhoneUnconfirmedTile(),
            ),
            const SizedBox(height: 8),
            // A carteira pode estar desligada no servidor.
            if (user.walletEnabled)
              ListTile(
                leading: const Icon(Icons.account_balance_wallet_outlined),
                title: const Text('Carteira'),
                trailing: Text(
                  kz(user.walletBalance),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                onTap: () => open(const WalletScreen()),
              ),
            if (user.star)
              ListTile(
                leading: const Icon(Icons.add_location_alt_outlined),
                title: const Text('Registar locais'),
                subtitle: const Text('Utilizador estrela · enriqueça o mapa'),
                onTap: () => open(const ContributeScreen()),
              ),
            if (!user.isDriver)
              ListTile(
                leading: const Icon(Icons.bookmark_outline),
                title: const Text('Locais guardados'),
                subtitle: const Text('Casa, trabalho e outros'),
                onTap: () => open(const SavedPlacesScreen()),
              ),
            if (!user.isDriver)
              ListTile(
                leading: const Icon(Icons.favorite_border),
                title: const Text('Motoristas preferidos'),
                onTap: () => open(const FavoritesScreen()),
              ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Histórico de corridas'),
              onTap: () => open(HistoryScreen(asDriver: user.isDriver)),
            ),
            if (user.isDriver) ...[
              ListTile(
                leading: const Icon(Icons.garage_outlined),
                title: const Text('As minhas viaturas'),
                subtitle: user.vehicle == null
                    ? null
                    : Text(
                        'Activa: ${categoryLabels[user.vehicle!.category] ?? ''} · ${user.vehicle!.plate}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                onTap: () => open(const GarageScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.airport_shuttle_outlined),
                title: const Text('Viagens entre municípios'),
                subtitle: const Text('Publicar uma viagem e gerir as reservas'),
                onTap: () => open(const IntercityScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.account_balance_wallet_outlined),
                title: const Text('O meu saldo'),
                subtitle: const Text(
                  'Carregar o saldo, viagens grátis e mensalidades',
                ),
                onTap: () => open(const DriverAccountScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.apartment_outlined),
                title: const Text('Frota'),
                subtitle: Text(user.fleetName ?? 'Motorista independente'),
                onTap: () => open(const FleetScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: const Text('Carta de condução'),
                onTap: () => open(const VehicleScreen()),
              ),
            ],
            ListTile(
              leading: const Icon(Icons.campaign_outlined),
              title: const Text('Avisos do Bazá'),
              onTap: () => open(const NoticesScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.support_agent),
              title: const Text('Ajuda e suporte'),
              onTap: () => open(const SupportScreen()),
            ),
            if (Servidores.activa)
              ListTile(
                leading: const Icon(Icons.cloud_off),
                title: const Text('Ligação ao servidor'),
                subtitle: Text(Servidores.activo.value.semSaldo ? 'Sem saldo de dados (angoschool.org)' : 'Principal'),
                onTap: () {
                  Navigator.of(context).pop();
                  abrirEscolhaServidor(context);
                },
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sair'),
              subtitle: onRide
                  ? const Text('Termine a corrida em curso primeiro.')
                  : null,
              enabled: !onRide,
              onTap: () {
                Navigator.of(context).pop();
                session.logout();
              },
            ),
          ],
        ),
      ),
    );
  }
}
