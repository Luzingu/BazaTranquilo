// Monta os ecrãs principais num telemóvel pequeno, em cada estado da corrida,
// para apanhar erros de construção e de layout (overflow).
import 'package:baza/core/models.dart';
import 'package:baza/core/theme.dart';
import 'package:baza/screens/auth_screen.dart';
import 'package:baza/screens/chat_screen.dart';
import 'package:baza/screens/driver_home.dart';
import 'package:baza/screens/fleet_screen.dart';
import 'package:baza/screens/garage_screen.dart';
import 'package:baza/screens/home_shell.dart';

import 'dart:convert';

import 'package:baza/widgets/common.dart';
import 'package:baza/widgets/document_photo.dart';
import 'package:baza/widgets/slide_action.dart';
import 'package:baza/screens/passenger_home.dart';
import 'package:baza/screens/profile_screen.dart';
import 'package:baza/screens/saved_places_screen.dart';
import 'package:baza/screens/splash_screen.dart';
import 'package:baza/screens/vehicle_screen.dart';
import 'package:baza/screens/call_screen.dart';
import 'package:baza/state/call_state.dart';
import 'package:baza/state/ride_state.dart';
import 'package:baza/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

const _vehicle = Vehicle(
  make: 'Toyota',
  carModel: 'Corolla',
  color: 'Branco',
  plate: 'LD-12-34-AB',
  category: 'economy',
);
const _passenger = RideParty(
  id: 'p1',
  name: 'Ana Maria dos Santos Francisco',
  phone: '+244923456789',
  rating: 4.8,
);
const _driver = RideParty(
  id: 'd1',
  name: 'José Manuel Kiala Domingos',
  phone: '+244911222333',
  vehicle: _vehicle,
  rating: 4.9,
);

User _user(String id, {bool driver = false}) => User(
  id: id,
  role: driver ? 'driver' : 'passenger',
  name: 'Ana Maria',
  phone: '+244923456789',
  vehicle: driver ? _vehicle : null,
  license: driver
      ? License(number: 'LD-123456', category: 'B', expiresAt: DateTime(2030))
      : null,
  verification: driver ? 'approved' : 'incomplete',
  walletBalance: 12500,
);

Ride _ride(String status, {String payment = 'cash', String? cancelledBy}) =>
    Ride(
      id: 'r1',
      status: status,
      pickup: const Place(
        address: 'Rua Rainha Ginga 152, Ingombota, Luanda',
        lat: -8.8383,
        lng: 13.2344,
      ),
      dropoff: const Place(
        address: 'Avenida Pedro de Castro Van-Dúnem Loy, Talatona',
        lat: -8.9147,
        lng: 13.1869,
      ),
      category: 'economy',
      paymentMethod: payment,
      distanceM: 14609,
      durationS: 1369,
      fare: 4850,
      passenger: _passenger,
      driver: status == 'searching' || status == 'no_drivers' ? null : _driver,
      cancelledBy: cancelledBy,
      createdAt: DateTime(2026, 11, 21, 10, 30),
    );

Future<void> _pump(
  WidgetTester tester,
  Session session,
  Widget child, {
  RideState? rides,
}) async {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: session),
        if (rides != null) ChangeNotifierProvider.value(value: rides),
        // As chamadas de voz dependem da corrida em curso.
        if (rides != null)
          ChangeNotifierProvider(create: (_) => CallState(session, rides)),
      ],
      child: MaterialApp(
        theme: bazaTheme(),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('login: só por telefone, com o tipo de conta', (tester) async {
    await _pump(tester, Session(), const AuthScreen());
    expect(find.text('Continuar'), findsOneWidget);
    expect(find.text('Tipo de conta'), findsOneWidget);
    // O login por email foi descontinuado: não há email nem palavra-passe.
    expect(find.textContaining('email'), findsNothing);
    expect(find.textContaining('alavra-passe'), findsNothing);
    // A tecla Enter no campo faz o mesmo que o botão: aqui valida o número.
    await tester.enterText(find.byType(TextField), '12');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('Escreva o seu número de telefone.'), findsOneWidget);
    // Trocar de perfil muda o texto de entrada.
    await tester.tap(find.text('Motorista'));
    await tester.pump();
    expect(
      find.text('Entre ou crie a sua conta de motorista.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'registo de motorista: carta com fotos, depois viatura com livrete',
    (tester) async {
      // Nos testes não há câmara: a "foto" é uma imagem de 1 píxel.
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      );
      pickPhotoOverride = () async => PickedPhoto(png, 'image/png');
      addTearDown(() => pickPhotoOverride = null);

      final session = Session()
        ..user = const User(
          id: 'd1',
          role: 'driver',
          name: 'Zé',
          walletBalance: 0,
        );
      await _pump(tester, session, const VehicleScreen(onboarding: true));
      expect(find.text('Passo 1 de 2'), findsOneWidget);
      // Com a foto de perfil no topo, o campo do número da carta continua logo
      // a seguir: cabe no primeiro ecrã de um telemóvel comum (≈ 760 de altura).
      final number = find.widgetWithText(
        TextField,
        'Número da carta de condução',
      );
      expect(number, findsOneWidget);
      expect(tester.getRect(number).bottom, lessThan(760));

      // O resto do teste usa um ecrã alto, para o formulário caber inteiro.
      tester.view.physicalSize = const Size(412, 1800);
      await tester.pump();

      Future<void> tapText(String text) async {
        await tester.ensureVisible(find.text(text));
        await tester.pumpAndSettle();
        await tester.tap(find.text(text));
        await tester.pumpAndSettle();
      }

      // Continuar sem preencher marca tudo o que falta, junto de cada campo.
      await tapText('Continuar');
      expect(
        find.text('Escreva o número da sua carta (mínimo 4 caracteres)'),
        findsOneWidget,
      );
      expect(find.text('Toque para escolher a data'), findsOneWidget);
      expect(find.text('Falta a foto da frente'), findsOneWidget);
      expect(find.text('Falta a foto do verso'), findsOneWidget);
      expect(find.text('Passo 1 de 2'), findsOneWidget);

      // Com os dados e as duas fotos, passa para a viatura.
      // …e sem foto de perfil também não: é obrigatória para motoristas.
      expect(find.text('A foto de perfil é obrigatória'), findsOneWidget);
      session.setUser(
        const User(
          id: 'd1',
          role: 'driver',
          name: 'Zé',
          walletBalance: 0,
          photoUrl: '/uploads/foto',
        ),
      );
      await tester.pump();
      await tester.enterText(number, 'LD-123456');
      await tapText('Escolher data');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      // Toca em cada cartão de foto (o primeiro que ainda mostra "Fotografar").
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byIcon(Icons.add_a_photo_outlined).first);
        await tester.pumpAndSettle();
      }
      expect(find.text('Frente da carta'), findsOneWidget);
      expect(find.text('Verso da carta'), findsOneWidget);
      await tapText('Continuar');
      expect(find.text('Passo 2 de 2'), findsOneWidget);
      expect(find.text('Tipo de viatura'), findsOneWidget);

      // A viatura pede a cor de uma lista, o ar condicionado e a foto do livrete.
      await tapText('Escolher cor');
      expect(find.text('Vermelho'), findsOneWidget);
      await tester.tap(find.text('Vermelho'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Documentos da viatura'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Livrete'), findsOneWidget);
      expect(find.text('Título de propriedade'), findsOneWidget);
      expect(find.text('Seguro'), findsOneWidget);
      expect(find.text('Validade do seguro'), findsOneWidget);
      expect(find.text('Tem ar condicionado'), findsOneWidget);
      // Ligar o ar condicionado num Económico activa o modo conforto.
      await tapText('Tem ar condicionado');
      expect(find.text('Conforto'), findsOneWidget);
      expect(
        find.textContaining('recebe pedidos Conforto e também Económico'),
        findsOneWidget,
      );
    },
  );

  testWidgets('passageiro: todos os estados da corrida', (tester) async {
    final session = Session()..user = _user('p1');
    final rides = RideState(session)..loaded = true;
    await _pump(tester, session, const PassengerHome(), rides: rides);
    expect(find.text('Para onde?'), findsOneWidget);

    final expected = {
      'searching': 'À procura de motorista…',
      'accepted': 'Motorista a caminho',
      'arrived': 'O motorista chegou',
      'in_progress': 'Em viagem',
      'completed': 'Chegou ao destino',
      'no_drivers': 'Sem motoristas disponíveis',
      'cancelled': 'Corrida cancelada',
    };
    for (final entry in expected.entries) {
      rides.setRide(
        _ride(entry.key, payment: 'multicaixa', cancelledBy: 'driver'),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(entry.value), findsOneWidget, reason: entry.key);
      // Com motorista atribuído há sempre os botões de segurança.
      final onTrip = const [
        'accepted',
        'arrived',
        'in_progress',
      ].contains(entry.key);
      expect(
        find.text('SOS'),
        onTrip ? findsOneWidget : findsNothing,
        reason: entry.key,
      );
      expect(
        find.text('Partilhar viagem'),
        onTrip ? findsOneWidget : findsNothing,
        reason: entry.key,
      );
      // …e os botões para falar com o motorista.
      expect(
        find.text('Mensagem'),
        onTrip ? findsOneWidget : findsNothing,
        reason: entry.key,
      );
      expect(
        find.text('Ligar ao motorista'),
        onTrip ? findsOneWidget : findsNothing,
        reason: entry.key,
      );
    }
    // Pedido directo a um motorista preferido.
    rides.setRide(
      Ride(
        id: 'r2',
        status: 'searching',
        pickup: _ride('searching').pickup,
        dropoff: _ride('searching').dropoff,
        category: 'economy',
        paymentMethod: 'cash',
        distanceM: 1000,
        durationS: 300,
        fare: 1000,
        passenger: _passenger,
        preferredDriverName: 'José Manuel',
        exclusive: true,
        createdAt: DateTime(2026, 11, 21),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('A chamar José Manuel…'), findsOneWidget);
    rides.setRide(_ride('cancelled', cancelledBy: 'driver'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.text('LD-12-34-AB'),
      findsNothing,
    ); // corrida cancelada não mostra motorista
    await tester.pumpWidget(const SizedBox());
    rides.dispose();
  });

  testWidgets('motorista: offline e todos os estados da corrida', (
    tester,
  ) async {
    final session = Session()..user = _user('d1', driver: true);
    final rides = RideState(session)..loaded = true;
    await _pump(tester, session, const DriverHome(), rides: rides);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Ficar online'), findsOneWidget);

    final expected = {
      'accepted': 'Cheguei',
      'arrived': 'Iniciar viagem',
      'in_progress': 'Terminar viagem',
      'completed': 'Viagem terminada',
      'cancelled': 'Corrida cancelada',
    };
    for (final entry in expected.entries) {
      rides.setRide(_ride(entry.key));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(entry.value), findsOneWidget, reason: entry.key);
    }
    // O motorista tem navegação até ao passageiro e, em viagem, até ao destino.
    rides.setRide(_ride('accepted'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Navegar até ao passageiro'), findsOneWidget);
    rides.setRide(_ride('in_progress'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Navegar até ao destino'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    rides.dispose();
  });

  testWidgets('os meus dados: mostra e permite editar', (tester) async {
    await _pump(tester, Session()..user = _user('p1'), const ProfileScreen());
    expect(find.widgetWithText(TextField, 'Ana Maria'), findsOneWidget);
    expect(find.text('+244923456789'), findsOneWidget);
    expect(find.text('Guardar'), findsOneWidget);
    // Não há palavras-passe: entra-se sempre com o telefone.
    expect(find.textContaining('alavra-passe'), findsNothing);
    expect(find.text('Email (opcional)'), findsOneWidget);
    await tester.tap(find.text('Alterar'));
    await tester.pumpAndSettle();
    expect(find.text('Novo número de telefone'), findsOneWidget);
  });

  testWidgets('ecrã principal: logótipo à esquerda e menu à direita', (
    tester,
  ) async {
    await _pump(tester, Session()..user = _user('p1'), const HomeShell());
    await tester.pump(const Duration(seconds: 1));
    final logo = tester.getCenter(find.byType(BazaLogo));
    final menu = tester.getCenter(find.bySemanticsLabel('Menu'));
    expect(logo.dx, lessThan(160));
    expect(menu.dx, greaterThan(160));
    expect((logo.dy - menu.dy).abs(), lessThan(4)); // na mesma linha, no topo
    expect(menu.dy, lessThan(80));

    await tester.tap(find.bySemanticsLabel('Menu'));
    await tester.pumpAndSettle();
    expect(find.text('Motoristas preferidos'), findsOneWidget);
    // O botão de editar fica junto ao nome e abre "Os meus dados".
    await tester.tap(find.byTooltip('Editar os meus dados'));
    await tester.pumpAndSettle();
    expect(find.text('Os meus dados'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Ana Maria'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('garagem: várias viaturas de categorias diferentes', (
    tester,
  ) async {
    final user = User(
      id: 'd1',
      role: 'driver',
      name: 'Zé',
      walletBalance: 0,
      vehicle: _vehicle,
      vehicles: [
        Vehicle(
          id: 'v1',
          make: 'Toyota',
          carModel: 'Corolla',
          color: 'Branco',
          plate: 'LD-12-34-AB',
          category: 'economy',
          active: true,
          hasRegistration: true,
          hasOwnership: true,
          hasInsurance: true,
          insuranceExpiresAt: DateTime(2035),
          status: 'approved',
        ),
        Vehicle(
          id: 'v2',
          make: 'Mitsubishi',
          carModel: 'Canter',
          color: 'Azul',
          plate: 'LD-22-22-BB',
          category: 'truck',
          hasRegistration: true,
          hasOwnership: true,
          hasInsurance: true,
          insuranceExpiresAt: DateTime(2035),
          status: 'approved',
        ),
        // Ainda sem livrete: não pode ser usada.
        Vehicle(
          id: 'v3',
          make: 'Keweseki',
          carModel: 'KW150',
          color: 'Vermelho',
          plate: 'LD-33-33-CC',
          category: 'cargo_tricycle',
        ),
      ],
    );
    await _pump(tester, Session()..user = user, const GarageScreen());
    expect(find.text('Viatura activa'), findsOneWidget);
    expect(find.text('Usar esta'), findsOneWidget);
    expect(find.text('Completar documentos'), findsOneWidget);
    expect(find.textContaining('Camião'), findsOneWidget);
    expect(find.textContaining('Triciclo de carga'), findsOneWidget);

    // O formulário de nova viatura lista todos os tipos, de passageiros e de carga.
    await tester.tap(find.text('Adicionar viatura'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tipo de viatura'));
    await tester.pumpAndSettle();
    expect(find.text('Transporte de passageiros'), findsOneWidget);
    expect(find.text('Triciclo'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Camião'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Carga e entregas'), findsOneWidget);
  });

  testWidgets('pedido de carga mostra a mercadoria e os ajudantes', (
    tester,
  ) async {
    final session = Session()..user = _user('d1', driver: true);
    final rides = RideState(session)..loaded = true;
    await _pump(tester, session, const DriverHome(), rides: rides);
    rides.setRide(
      Ride(
        id: 'r3',
        status: 'accepted',
        pickup: _ride('accepted').pickup,
        dropoff: _ride('accepted').dropoff,
        category: 'truck',
        group: 'cargo',
        cargoNote: 'Mudança: sofá e 10 caixas',
        helpers: 2,
        paymentMethod: 'cash',
        distanceM: 14000,
        durationS: 1300,
        fare: 23000,
        passenger: _passenger,
        driver: _driver,
        createdAt: DateTime(2026, 11, 21),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.text('Camião: Mudança: sofá e 10 caixas · 2 ajudantes'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    rides.dispose();
  });

  group('botão de deslizar', () {
    Future<void> pumpSlider(
      WidgetTester tester,
      Future<void> Function() onSubmit, {
      bool reversed = false,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: SlideAction(
                label: 'Iniciar viagem',
                reversed: reversed,
                onSubmit: onSubmit,
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('um toque ou um deslize curto não confirmam', (tester) async {
      var calls = 0;
      await pumpSlider(tester, () async => calls++);
      await tester.tap(find.byType(SlideAction));
      await tester.drag(find.byType(SlideAction), const Offset(90, 0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls, 0);
    });

    testWidgets('deslizar até ao fim confirma uma vez', (tester) async {
      var calls = 0;
      await pumpSlider(tester, () async => calls++);
      // Começa no polegar, à esquerda, e arrasta até ao fim da pista.
      final start =
          tester.getTopLeft(find.byType(SlideAction)) + const Offset(30, 30);
      await tester.dragFrom(start, const Offset(300, 0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls, 1);
    });

    testWidgets('invertido: confirma ao deslizar para a esquerda', (
      tester,
    ) async {
      var calls = 0;
      await pumpSlider(tester, () async => calls++, reversed: true);
      final start =
          tester.getTopRight(find.byType(SlideAction)) + const Offset(-30, 30);
      await tester.dragFrom(start, const Offset(300, 0)); // sentido errado
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls, 0);
      await tester.dragFrom(start, const Offset(-300, 0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls, 1);
    });
  });

  testWidgets('selo da viatura usa a cor da viatura', (tester) async {
    const red = Vehicle(
      make: 'Kia',
      carModel: 'Rio',
      color: 'Vermelho',
      plate: 'LD-1',
      category: 'economy',
    );
    const white = Vehicle(
      make: 'Kia',
      carModel: 'Rio',
      color: 'Branco',
      plate: 'LD-2',
      category: 'truck',
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Row(
          children: [
            VehicleBadge(vehicle: red),
            VehicleBadge(vehicle: white),
          ],
        ),
      ),
    );
    final icons = tester.widgetList<Icon>(find.byType(Icon)).toList();
    expect(icons[0].color, const Color(0xFFDC2626));
    expect(icons[1].color, const Color(0xFFFFFFFF));
    expect(icons[1].icon, Icons.local_shipping);
  });

  testWidgets('guardar local: usa o ponto actual e pede um nome', (
    tester,
  ) async {
    late BuildContext ctx;
    await _pump(
      tester,
      Session()..user = _user('p1'),
      Builder(
        builder: (context) {
          ctx = context;
          return const SizedBox();
        },
      ),
    );
    addSavedPlace(ctx, kind: 'other');
    // Sem pumpAndSettle: enquanto procura o GPS há um indicador a rodar.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Guardar este local'), findsNWidgets(2)); // título e botão
    expect(find.text('Nome do local'), findsOneWidget);
    expect(find.text('Procurar outro endereço'), findsOneWidget);
    // Sem localização o botão de guardar fica desligado.
    expect(
      tester.widget<AsyncButton>(find.byType(AsyncButton)).onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('negociação: passageiro vê propostas e pode mudar o preço', (
    tester,
  ) async {
    final session = Session()..user = _user('p1');
    final rides = RideState(session)..loaded = true;
    await _pump(tester, session, const PassengerHome(), rides: rides);
    tester.view.physicalSize = const Size(412, 1800);
    rides.setRide(
      Ride(
        id: 'r9',
        status: 'searching',
        pickup: _ride('searching').pickup,
        dropoff: _ride('searching').dropoff,
        category: 'economy',
        paymentMethod: 'cash',
        distanceM: 14000,
        durationS: 1300,
        fare: 4000,
        suggestedFare: 4850,
        fareMin: 2450,
        fareMax: 14550,
        bids: const [RideBid(driver: _driver, amount: 5000)],
        passenger: _passenger,
        createdAt: DateTime(2026, 11, 21),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('O seu preço'), findsOneWidget);
    expect(find.text('Proposta de um motorista'), findsOneWidget);
    expect(find.text('Aceitar 5\u00A0000\u00A0Kz'), findsOneWidget);
    // Subir o preço mostra o botão para o confirmar.
    await tester.tap(find.byTooltip('Subir o preço'));
    await tester.pump();
    expect(find.text('Subir para 4\u00A0100\u00A0Kz'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    rides.dispose();
  });

  testWidgets('seletor de preço respeita os limites', (tester) async {
    var value = 2500;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => PriceStepper(
              value: value,
              min: 2450,
              max: 2600,
              reference: 2500,
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Baixar o preço'));
    await tester.pump();
    expect(value, 2450); // não desce abaixo do mínimo
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.remove))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Subir o preço'));
    await tester.tap(find.byTooltip('Subir o preço'));
    await tester.pump();
    await tester.tap(find.byTooltip('Subir o preço'));
    await tester.pump();
    expect(value, 2600);
  });

  testWidgets('SOS: mostra a chamada de emergência e os dados da viatura', (
    tester,
  ) async {
    final session = Session()..user = _user('p1');
    final rides = RideState(session)..loaded = true;
    await _pump(tester, session, const PassengerHome(), rides: rides);
    rides.setRide(_ride('in_progress'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.ensureVisible(find.text('SOS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SOS'));
    await tester.pumpAndSettle();
    expect(find.text('Emergência'), findsOneWidget);
    expect(find.text('Ligar para o 111'), findsOneWidget);
    expect(find.textContaining('matrícula LD-12-34-AB'), findsOneWidget);
    // Sem contacto de emergência definido, explica onde o definir.
    expect(find.textContaining('contacto de emergência'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    rides.dispose();
  });

  testWidgets('carteira desligada não aparece no menu', (tester) async {
    await _pump(tester, Session()..user = _user('p1'), const HomeShell());
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.bySemanticsLabel('Menu'));
    await tester.pumpAndSettle();
    expect(find.text('Carteira'), findsNothing);
    expect(find.text('Locais guardados'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('frota: motorista independente pode introduzir o código', (
    tester,
  ) async {
    await _pump(
      tester,
      Session()..user = _user('d1', driver: true),
      const FleetScreen(),
    );
    expect(find.text('Motorista independente'), findsOneWidget);
    expect(find.text('Código da frota'), findsOneWidget);
    await tester.ensureVisible(find.text('Juntar-me à frota'));
    await tester.tap(find.text('Juntar-me à frota'));
    await tester.pump();
    expect(find.text('Escreva o código que a frota lhe deu.'), findsOneWidget);
  });

  testWidgets('paragens aparecem no resumo do percurso', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RouteSummary(
            pickup: 'Mutamba',
            dropoff: 'Talatona',
            stops: ['Ilha de Luanda', 'Maianga'],
          ),
        ),
      ),
    );
    final ys = [
      for (final t in ['Mutamba', 'Ilha de Luanda', 'Maianga', 'Talatona'])
        tester.getTopLeft(find.text(t)).dy,
    ];
    expect(ys, orderedEquals([...ys]..sort())); // pela ordem do percurso
    expect(find.byIcon(Icons.stop_circle_outlined), findsNWidgets(2));
  });

  testWidgets('chat: respostas rápidas e campo de mensagem', (tester) async {
    final session = Session()..user = _user('p1');
    final rides = RideState(session)..loaded = true;
    final ride = _ride('accepted');
    rides.setRide(ride);
    // Abrir o chat com mensagens por ler (foi o que causou um erro no ecrã).
    rides.unreadMessages = 2;
    await _pump(
      tester,
      session,
      ChatScreen(ride: ride, other: _driver, iAmDriver: false),
      rides: rides,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('José Manuel Kiala Domingos'), findsOneWidget);
    expect(
      find.text('Já estou no local'),
      findsOneWidget,
    ); // resposta rápida do passageiro
    expect(find.text('Escreva uma mensagem'), findsOneWidget);
    expect(find.byTooltip('Ligar'), findsOneWidget);
    expect(rides.chatOpen, isTrue);
    expect(rides.unreadMessages, 0); // ficam lidas ao abrir
    await tester.pumpWidget(const SizedBox());
    expect(rides.chatOpen, isFalse);
    rides.dispose();
  });

  testWidgets('ecrã de arranque: nome completo e lema', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SplashScreen()));
    await tester.pump(const Duration(seconds: 2)); // fim da animação de entrada
    expect(find.bySemanticsLabel('Bazá Tranquilo'), findsOneWidget);
    expect(find.text('Bazá com Segurança'), findsOneWidget);
    expect(find.bySemanticsLabel('A carregar'), findsOneWidget);
    // Com erro, explica e oferece tentar de novo em vez da barra de carregamento.
    await tester.pumpWidget(
      MaterialApp(
        home: SplashScreen(
          error: 'Sem ligação ao servidor.',
          onRetry: () async {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Sem ligação ao servidor.'), findsOneWidget);
    expect(find.text('Tentar novamente'), findsOneWidget);
    // Com o telemóvel deitado (pouca altura) não pode transbordar: o conteúdo desloca-se.
    tester.view.physicalSize = const Size(640, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pump();
    await tester.ensureVisible(find.text('Tentar novamente'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('chamada no app: a tocar, em conversa e terminada', (
    tester,
  ) async {
    final session = Session()..user = _user('p1');
    final rides = RideState(session)..loaded = true;
    final call = CallState(session, rides);
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: call,
        child: const MaterialApp(home: CallScreen()),
      ),
    );

    call.debugSet(
      CallPhase.incoming,
      forRide: _ride('accepted'),
      withPeer: _driver,
    );
    await tester.pump();
    expect(find.text('José Manuel Kiala Domingos'), findsOneWidget);
    expect(find.text('Atender'), findsOneWidget);
    expect(find.text('Recusar'), findsOneWidget);
    expect(find.textContaining('o seu número não é mostrado'), findsOneWidget);

    call.debugSet(CallPhase.active);
    await tester.pump();
    expect(find.text('00:00'), findsOneWidget);
    expect(find.text('Desligar'), findsOneWidget);
    expect(find.text('Silenciar'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Silenciar'));
    await tester.pump();
    expect(call.muted, isTrue);
    expect(find.text('Microfone desligado'), findsOneWidget);

    call.debugSet(CallPhase.ended, reason: 'Chamada recusada.');
    await tester.pump();
    expect(find.text('Chamada recusada.'), findsOneWidget);
    expect(find.text('Desligar'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    call.dispose();
    rides.dispose();
  });
}
