import 'package:latlong2/latlong.dart';

double _d(dynamic v) => (v as num).toDouble();

class Vehicle {
  const Vehicle({
    this.id,
    required this.make,
    required this.carModel,
    required this.color,
    required this.plate,
    required this.category,
    this.hasAC = false,
    this.active = false,
    this.hasRegistration = false,
    this.hasOwnership = false,
    this.hasInsurance = false,
    this.insuranceExpiresAt,
    this.status = 'pending',
    this.reviewNote,
    this.monthlyFee = 0,
    this.subscription = 'none',
    this.paidUntil,
  });

  /// Id na garagem do motorista (null numa viatura ainda por guardar).
  final String? id;
  final String make, carModel, color, plate, category;

  /// Tem ar condicionado. É o que permite o "modo conforto": uma viatura
  /// Conforto recebe pedidos Conforto e também Económico.
  final bool hasAC;

  /// Se é a viatura com que o motorista está a conduzir.
  final bool active;

  /// Documentos da viatura já enviados (livrete, título de propriedade, seguro),
  /// a validade do seguro e o estado da revisão.
  final bool hasRegistration, hasOwnership, hasInsurance;
  final DateTime? insuranceExpiresAt;
  final String status;
  final String? reviewNote;

  /// Mensalidade deste tipo de viatura (0 = não paga) e o estado:
  /// 'none', 'free', 'trial', 'active' ou 'expired'.
  final int monthlyFee;
  final String subscription;
  final DateTime? paidUntil;

  /// Tem todos os documentos e a validade do seguro.
  bool get docsComplete =>
      hasRegistration &&
      hasOwnership &&
      hasInsurance &&
      insuranceExpiresAt != null;

  /// Pode ser usada para conduzir: documentos completos e aprovados.
  bool get usable => docsComplete && status == 'approved';

  factory Vehicle.fromJson(Map<String, dynamic> j) => Vehicle(
    id: j['id'] as String?,
    make: j['make'] as String,
    carModel: j['carModel'] as String,
    color: j['color'] as String,
    plate: j['plate'] as String,
    category: j['category'] as String? ?? 'economy',
    hasAC: j['hasAC'] as bool? ?? false,
    active: j['active'] as bool? ?? false,
    hasRegistration: j['hasRegistration'] as bool? ?? false,
    hasOwnership: j['hasOwnership'] as bool? ?? false,
    hasInsurance: j['hasInsurance'] as bool? ?? false,
    insuranceExpiresAt: j['insuranceExpiresAt'] == null
        ? null
        : DateTime.parse(j['insuranceExpiresAt'] as String).toLocal(),
    status: j['status'] as String? ?? 'pending',
    reviewNote: j['reviewNote'] as String?,
    monthlyFee: (j['monthlyFee'] as num? ?? 0).round(),
    subscription: j['subscription'] as String? ?? 'none',
    paidUntil: j['paidUntil'] == null
        ? null
        : DateTime.parse(j['paidUntil'] as String).toLocal(),
  );
  Map<String, dynamic> toJson() => {
    'make': make,
    'carModel': carModel,
    'color': color,
    'plate': plate,
    'category': category,
    'hasAC': hasAC,
    if (insuranceExpiresAt != null)
      'insuranceExpiresAt': insuranceExpiresAt!.toUtc().toIso8601String(),
  };

  String get description => '$color · $make $carModel';
}

/// Carta de condução do motorista. As fotos (frente e verso) ficam no servidor
/// e passam por revisão: [status] é 'pending', 'approved' ou 'rejected'.
class License {
  const License({
    required this.number,
    required this.category,
    required this.expiresAt,
    this.hasFront = false,
    this.hasBack = false,
    this.status = 'pending',
    this.reviewNote,
  });
  final String number, category;
  final DateTime expiresAt;
  final bool hasFront, hasBack;
  final String status;

  /// Motivo da rejeição, quando [status] é 'rejected'.
  final String? reviewNote;

  factory License.fromJson(Map<String, dynamic> j) => License(
    number: j['number'] as String,
    category: j['category'] as String,
    expiresAt: DateTime.parse(j['expiresAt'] as String).toLocal(),
    hasFront: j['hasFront'] as bool? ?? false,
    hasBack: j['hasBack'] as bool? ?? false,
    status: j['status'] as String? ?? 'pending',
    reviewNote: j['reviewNote'] as String?,
  );
  Map<String, dynamic> toJson() => {
    'number': number,
    'category': category,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };
}

class User {
  const User({
    required this.id,
    required this.role,
    required this.name,
    this.phone,
    this.email,
    this.photoUrl,
    this.hasPassword = false,
    this.phoneVerified = true,
    this.walletEnabled = false,
    this.star = false,
    this.emergencyName,
    this.emergencyPhone,
    this.vehicle,
    this.vehicles = const [],
    this.license,
    this.verification = 'incomplete',
    this.fleetName,
    this.blocked = false,
    this.isOnline = false,
    required this.walletBalance,
    this.rating,
  });
  final String id, name;

  /// 'passenger' ou 'driver'. Cada número de telefone só tem um tipo de conta.
  final String role;
  final String? phone, email, photoUrl;

  /// Se já definiu palavra-passe para entrar com email.
  final bool hasPassword;

  /// false quando a conta foi criada sem o SMS chegar: o número está por
  /// confirmar e o app pede o código quando o SMS voltar a funcionar.
  final bool phoneVerified;

  /// Se a carteira está disponível no app (pode estar desligada no servidor).
  final bool walletEnabled;

  /// Utilizador estrela: pode registar locais no mapa.
  final bool star;

  /// Contacto de emergência: a quem enviar a localização num SOS.
  final String? emergencyName, emergencyPhone;

  /// A viatura activa do motorista.
  final Vehicle? vehicle;

  /// Todas as viaturas registadas pelo motorista.
  final List<Vehicle> vehicles;
  final License? license;
  final bool isOnline;
  final int walletBalance;
  final double? rating;

  bool get isDriver => role == 'driver';

  /// Frota a que o motorista pertence, se pertencer a alguma.
  final String? fleetName;

  /// Conta suspensa por um administrador.
  final bool blocked;

  /// Situação dos documentos do motorista: 'incomplete' (falta enviar algo),
  /// 'pending' (em análise), 'rejected' ou 'approved'.
  final String verification;

  /// O registo está completo quando a carta (com fotos) e o livrete foram enviados.
  bool get driverProfileComplete => verification != 'incomplete';

  factory User.fromJson(Map<String, dynamic> j) => User(
    id: j['id'] as String,
    role: j['role'] as String? ?? 'passenger',
    name: j['name'] as String? ?? '',
    phone: j['phone'] as String?,
    email: j['email'] as String?,
    photoUrl: j['photoUrl'] as String?,
    hasPassword: j['hasPassword'] as bool? ?? false,
    phoneVerified: j['phoneVerified'] as bool? ?? true,
    walletEnabled: j['walletEnabled'] as bool? ?? false,
    star: j['star'] as bool? ?? false,
    emergencyName:
        (j['emergencyContact'] as Map<String, dynamic>?)?['name'] as String?,
    emergencyPhone:
        (j['emergencyContact'] as Map<String, dynamic>?)?['phone'] as String?,
    vehicle: j['vehicle'] == null
        ? null
        : Vehicle.fromJson(j['vehicle'] as Map<String, dynamic>),
    vehicles: [
      for (final v in j['vehicles'] as List? ?? const [])
        Vehicle.fromJson(Map<String, dynamic>.from(v as Map)),
    ],
    license: j['license'] == null
        ? null
        : License.fromJson(j['license'] as Map<String, dynamic>),
    verification: j['verification'] as String? ?? 'incomplete',
    fleetName: (j['fleet'] as Map<String, dynamic>?)?['name'] as String?,
    blocked: j['blocked'] as bool? ?? false,
    isOnline: j['isOnline'] as bool? ?? false,
    walletBalance: (j['walletBalance'] as num? ?? 0).round(),
    rating: j['rating'] == null ? null : _d(j['rating']),
  );
}

class Place {
  const Place({required this.address, required this.lat, required this.lng});
  final String address;
  final double lat, lng;

  LatLng get latLng => LatLng(lat, lng);

  factory Place.fromJson(Map<String, dynamic> j) => Place(
    address: j['address'] as String,
    lat: _d(j['lat']),
    lng: _d(j['lng']),
  );
  Map<String, dynamic> toJson() => {'address': address, 'lat': lat, 'lng': lng};
}

/// A outra pessoa da corrida (motorista ou passageiro).
class RideParty {
  const RideParty({
    required this.id,
    required this.name,
    this.phone,
    this.photoUrl,
    this.vehicle,
    this.rating,
  });
  final String id, name;
  final String? phone, photoUrl;
  final Vehicle? vehicle;
  final double? rating;

  factory RideParty.fromJson(Map<String, dynamic> j) => RideParty(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    phone: j['phone'] as String?,
    photoUrl: j['photoUrl'] as String?,
    vehicle: j['vehicle'] == null
        ? null
        : Vehicle.fromJson(j['vehicle'] as Map<String, dynamic>),
    rating: j['rating'] == null ? null : _d(j['rating']),
  );
}

/// Motorista preferido do passageiro, com a disponibilidade actual.
class FavoriteDriver {
  const FavoriteDriver({
    required this.driver,
    required this.available,
    this.distanceM,
  });
  final RideParty driver;
  final bool available;
  final int? distanceM;

  factory FavoriteDriver.fromJson(Map<String, dynamic> j) => FavoriteDriver(
    driver: RideParty.fromJson(j),
    available: j['available'] as bool? ?? false,
    distanceM: (j['distanceM'] as num?)?.round(),
  );
}

/// Proposta de preço de um motorista, vista pelo passageiro.
class RideBid {
  const RideBid({required this.driver, required this.amount});
  final RideParty driver;
  final int amount;

  factory RideBid.fromJson(Map<String, dynamic> j) => RideBid(
    driver: RideParty.fromJson(j['driver'] as Map<String, dynamic>),
    amount: (j['amount'] as num).round(),
  );
}

class Ride {
  const Ride({
    required this.id,
    required this.status,
    required this.pickup,
    required this.dropoff,
    required this.category,
    this.group = 'ride',
    this.stops = const [],
    this.suggestedFare,
    this.fareMin,
    this.fareMax,
    this.bids = const [],
    this.myBid,
    this.cargoNote,
    this.helpers = 0,
    this.negotiated = false,
    this.priceOpen = false,
    this.noDestination = false,
    required this.paymentMethod,
    required this.distanceM,
    required this.durationS,
    this.routeGeometry,
    required this.fare,
    this.passenger,
    this.driver,
    this.driverLocation,
    this.preferredDriverName,
    this.exclusive = false,
    this.cancelledBy,
    this.passengerRating,
    this.driverRating,
    required this.createdAt,
  });
  final String id, status, category, paymentMethod;
  final Place pickup, dropoff;
  final int distanceM, durationS, fare;
  final String? routeGeometry, cancelledBy;
  final RideParty? passenger, driver;
  final LatLng? driverLocation;
  final int? passengerRating, driverRating;

  /// Paragens intermédias, pela ordem em que se fazem.
  final List<Place> stops;

  /// Preço da tarifa (referência da negociação) e limites aceites.
  final int? suggestedFare, fareMin, fareMax;

  /// Propostas de preço dos motoristas (só o passageiro as recebe).
  final List<RideBid> bids;

  /// A proposta que este motorista fez, se fez alguma.
  final int? myBid;

  /// 'ride' (pessoas) ou 'cargo' (mercadoria).
  final String group;

  /// Em serviços de carga: o que se transporta e quantos ajudantes.
  final String? cargoNote;
  final int helpers;

  bool get isCargo => group == 'cargo';

  /// Preço combinado entre cliente e motorista; [priceOpen] enquanto ninguém
  /// propôs preço; [noDestination] quando o destino fica por combinar.
  final bool negotiated, priceOpen, noDestination;

  /// Motorista preferido chamado pelo passageiro, se houve.
  final String? preferredDriverName;

  /// true enquanto o pedido está reservado ao motorista preferido.
  final bool exclusive;
  final DateTime createdAt;

  bool get isActive => const [
    'searching',
    'accepted',
    'arrived',
    'in_progress',
  ].contains(status);

  factory Ride.fromJson(Map<String, dynamic> j) {
    final loc = j['driverLocation'] as Map<String, dynamic>?;
    return Ride(
      id: j['id'] as String,
      status: j['status'] as String,
      pickup: Place.fromJson(j['pickup'] as Map<String, dynamic>),
      dropoff: Place.fromJson(j['dropoff'] as Map<String, dynamic>),
      category: j['category'] as String,
      group: j['group'] as String? ?? 'ride',
      stops: [
        for (final p in j['stops'] as List? ?? const [])
          Place.fromJson(Map<String, dynamic>.from(p as Map)),
      ],
      suggestedFare: (j['suggestedFare'] as num?)?.round(),
      fareMin: ((j['fareBounds'] as Map<String, dynamic>?)?['min'] as num?)
          ?.round(),
      fareMax: ((j['fareBounds'] as Map<String, dynamic>?)?['max'] as num?)
          ?.round(),
      bids: [
        for (final b in j['bids'] as List? ?? const [])
          RideBid.fromJson(Map<String, dynamic>.from(b as Map)),
      ],
      myBid: (j['myBid'] as num?)?.round(),
      cargoNote: j['cargoNote'] as String?,
      negotiated: j['negotiated'] as bool? ?? false,
      priceOpen: j['priceOpen'] as bool? ?? false,
      noDestination: j['noDestination'] as bool? ?? false,
      helpers: (j['helpers'] as num? ?? 0).round(),
      paymentMethod: j['paymentMethod'] as String,
      distanceM: (j['distanceM'] as num).round(),
      durationS: (j['durationS'] as num).round(),
      routeGeometry: j['routeGeometry'] as String?,
      fare: (j['fare'] as num).round(),
      passenger: j['passenger'] == null
          ? null
          : RideParty.fromJson(j['passenger'] as Map<String, dynamic>),
      driver: j['driver'] == null
          ? null
          : RideParty.fromJson(j['driver'] as Map<String, dynamic>),
      driverLocation: loc == null
          ? null
          : LatLng(_d(loc['lat']), _d(loc['lng'])),
      preferredDriverName:
          (j['preferredDriver'] as Map<String, dynamic>?)?['name'] as String?,
      exclusive: j['exclusive'] as bool? ?? false,
      cancelledBy: j['cancelledBy'] as String?,
      passengerRating: (j['passengerRating'] as num?)?.round(),
      driverRating: (j['driverRating'] as num?)?.round(),
      createdAt: DateTime.parse(j['createdAt'] as String).toLocal(),
    );
  }
}

/// Um serviço do catálogo com o preço para o percurso pedido.
class FareOption {
  const FareOption({
    required this.category,
    required this.label,
    required this.fare,
    this.group = 'ride',
    this.description = '',
    this.seats,
    this.capacityKg,
    this.helpers = false,
    this.negotiated = false,
  });
  final String category, label, group, description;

  /// Preço da tarifa (0 nos serviços de preço combinado).
  final int fare;

  /// Preço combinado com o motorista, sem tarifa calculada.
  final bool negotiated;
  final int? seats, capacityKg;

  /// Se este serviço permite pedir ajudantes para carregar.
  final bool helpers;

  /// "Carro acessível · 4 lugares" / "Mudanças e cargas grandes · até 8 t"
  String get details {
    final extra = seats != null
        ? (seats == 1 ? '1 lugar' : '$seats lugares')
        : capacityKg == null
        ? null
        : capacityKg! >= 1000
        ? 'até ${(capacityKg! / 1000).toStringAsFixed(capacityKg! % 1000 == 0 ? 0 : 1).replaceAll('.', ',')} t'
        : 'até $capacityKg kg';
    return [description, ?extra].where((p) => p.isNotEmpty).join(' · ');
  }

  factory FareOption.fromJson(Map<String, dynamic> o) => FareOption(
    category: o['category'] as String,
    label: o['label'] as String,
    fare: (o['fare'] as num? ?? 0).round(),
    negotiated: o['negotiated'] as bool? ?? false,
    group: o['group'] as String? ?? 'ride',
    description: o['description'] as String? ?? '',
    seats: (o['seats'] as num?)?.round(),
    capacityKg: (o['capacityKg'] as num?)?.round(),
    helpers: o['helpers'] as bool? ?? false,
  );
}

class Estimate {
  const Estimate({
    required this.distanceM,
    required this.durationS,
    this.geometry,
    required this.options,
    required this.paymentMethods,
    this.helperFee = 0,
    this.maxHelpers = 0,
    this.stopFee = 0,
    this.maxStops = 3,
    this.minFactor = 0.5,
    this.maxFactor = 3,
    this.fareStep = 50,
  });
  final int distanceM, durationS;
  final String? geometry;
  final List<FareOption> options;
  final List<String> paymentMethods;

  /// Preço por ajudante e máximo de ajudantes, em serviços de carga.
  final int helperFee, maxHelpers;

  /// Custo de cada paragem intermédia e máximo de paragens.
  final int stopFee, maxStops;

  /// Negociação: o preço proposto pode ir de [minFactor]× a [maxFactor]× o
  /// preço da tarifa, em múltiplos de [fareStep] Kz.
  final double minFactor, maxFactor;
  final int fareStep;

  int minFare(int suggested) =>
      ((suggested * minFactor) / fareStep).ceil() * fareStep;
  int maxFare(int suggested) =>
      ((suggested * maxFactor) / fareStep).ceil() * fareStep;

  factory Estimate.fromJson(Map<String, dynamic> j) => Estimate(
    distanceM: (j['distanceM'] as num).round(),
    durationS: (j['durationS'] as num).round(),
    geometry: j['geometry'] as String?,
    options: [
      for (final o in j['options'] as List)
        FareOption.fromJson(Map<String, dynamic>.from(o as Map)),
    ],
    paymentMethods: [for (final m in j['paymentMethods'] as List) m as String],
    helperFee: (j['helperFee'] as num? ?? 0).round(),
    maxHelpers: (j['maxHelpers'] as num? ?? 0).round(),
    stopFee: (j['stopFee'] as num? ?? 0).round(),
    maxStops: (j['maxStops'] as num? ?? 3).round(),
    minFactor:
        ((j['negotiation'] as Map<String, dynamic>?)?['minFactor'] as num? ??
                0.5)
            .toDouble(),
    maxFactor:
        ((j['negotiation'] as Map<String, dynamic>?)?['maxFactor'] as num? ?? 3)
            .toDouble(),
    fareStep:
        ((j['negotiation'] as Map<String, dynamic>?)?['step'] as num? ?? 50)
            .round(),
  );
}
