import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../core/config.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../state/session.dart';
import 'common.dart';

/// Mapa OpenStreetMap com os marcadores de uma corrida.
/// Sempre que [fitKey] muda, a câmara ajusta-se aos pontos visíveis.
class BazaMap extends StatefulWidget {
  const BazaMap({
    super.key,
    this.me,
    this.pickup,
    this.dropoff,
    this.driver,
    this.driverVehicle,
    this.follow,
    this.followTarget,
    this.tripRoute = const [],
    this.labels = false,
    this.meIsCar = false,
    this.stops = const [],
    this.alert,
    this.route = const [],
    this.bottomPadding = 0,
    this.fitKey = '',
  });

  final LatLng? me;
  final LatLng? pickup;
  final LatLng? dropoff;
  final LatLng? driver;

  /// Viatura do motorista, para desenhar o marcador na cor dela.
  final Vehicle? driverVehicle;
  final List<LatLng> route;

  /// Ponto a manter à vista (o carro, durante a corrida). A câmara acompanha-o
  /// enquanto o utilizador não mexer no mapa.
  final LatLng? follow;

  /// Próximo ponto da corrida (recolha ou destino): ao seguir o carro, o mapa
  /// mantém os dois à vista.
  final LatLng? followTarget;

  /// Percurso da viagem (recolha → destino), desenhado mais claro por baixo do
  /// percurso principal enquanto o motorista ainda vai a caminho da recolha.
  final List<LatLng> tripRoute;

  /// Mostra os nomes "Recolha", "Destino" e o número das paragens nos marcadores.
  final bool labels;

  /// O ponto [me] é a viatura do motorista (desenha um carro em vez do ponto azul).
  final bool meIsCar;

  /// Paragens intermédias da corrida.
  final List<LatLng> stops;

  /// Onde foi accionado um alerta de perigo (área do agente).
  final LatLng? alert;
  final double bottomPadding;
  final String fitKey;

  @override
  State<BazaMap> createState() => BazaMapState();
}

class BazaMapState extends State<BazaMap> with SingleTickerProviderStateMixin {
  final _controller = MapController();
  bool _ready = false;

  // Depois de o utilizador arrastar o mapa, deixa-se de seguir o carro até ele
  // tocar em "recentrar": o mapa nunca lhe foge das mãos.
  bool _userMoved = false;

  // O marcador do motorista desliza de uma posição para a seguinte em vez de saltar.
  late final _glide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  LatLng? _driverFrom, _driverShown;

  // Locais registados pela equipa e pelos utilizadores estrela: aparecem no
  // mapa com o nome, a partir de uma certa ampliação, e actualizam-se quando o
  // mapa se move.
  static const _placesMinZoom = 13.5;
  List<({String name, LatLng point})> _places = const [];
  Timer? _placesTimer;
  String _placesKey = '';

  void _schedulePlaces() {
    _placesTimer?.cancel();
    _placesTimer = Timer(const Duration(milliseconds: 600), _loadPlaces);
  }

  Future<void> _loadPlaces() async {
    if (!_ready || !mounted) return;
    final camera = _controller.camera;
    if (camera.zoom < _placesMinZoom) {
      if (_places.isNotEmpty) setState(() => _places = const []);
      _placesKey = '';
      return;
    }
    // Pede uma zona um pouco maior do que a visível, arredondada, para não
    // repetir o pedido a cada pequeno movimento.
    final b = camera.visibleBounds;
    final padLat = (b.north - b.south) * 0.5, padLng = (b.east - b.west) * 0.5;
    double r(double v) => (v * 50).roundToDouble() / 50;
    final south = r(b.south - padLat), north = r(b.north + padLat);
    final west = r(b.west - padLng), east = r(b.east + padLng);
    final key = '$south,$north,$west,$east';
    if (key == _placesKey) return;
    try {
      final session = Provider.of<Session>(context, listen: false);
      if (session.user == null) return;
      final res = await session.api.get('/places/near', {
        'south': '$south',
        'north': '$north',
        'west': '$west',
        'east': '$east',
      });
      if (!mounted) return;
      _placesKey = key;
      setState(
        () => _places = [
          for (final p in (res['places'] as List).cast<Map<String, dynamic>>())
            (
              name: p['name'] as String,
              point: LatLng(
                (p['lat'] as num).toDouble(),
                (p['lng'] as num).toDouble(),
              ),
            ),
        ],
      );
    } catch (_) {
      // Sem sessão ou sem rede: o mapa fica só com o que já tem.
    }
  }

  LatLng? get _driverPoint {
    final to = widget.driver;
    final from = _driverFrom;
    if (to == null) return null;
    if (from == null || !_glide.isAnimating) return to;
    final t = Curves.easeInOut.transform(_glide.value);
    return LatLng(
      from.latitude + (to.latitude - from.latitude) * t,
      from.longitude + (to.longitude - from.longitude) * t,
    );
  }

  @override
  void initState() {
    super.initState();
    _driverShown = widget.driver;
    _glide.addListener(() => setState(() => _driverShown = _driverPoint));
  }

  void _followNow() {
    final target = widget.follow;
    if (!_ready || !mounted || target == null) return;
    final next = widget.followTarget;
    if (next != null) {
      // Carro e próximo ponto sempre à vista; aproxima à medida que se chega.
      _controller.fitCamera(
        CameraFit.coordinates(
          coordinates: [target, next],
          maxZoom: 17,
          padding: EdgeInsets.fromLTRB(56, 130, 56, widget.bottomPadding + 56),
        ),
      );
      return;
    }
    // Centra um pouco acima do meio, porque o painel de baixo tapa parte do mapa.
    _controller.move(
      target,
      _controller.camera.zoom,
      offset: Offset(0, -widget.bottomPadding / 3),
    );
  }

  void recenter() {
    setState(() => _userMoved = false);
    if (widget.follow != null) {
      _followNow();
    } else {
      fit();
    }
  }

  @override
  void didUpdateWidget(BazaMap old) {
    super.didUpdateWidget(old);
    final gotFirstFix = old.me == null && widget.me != null;
    if (old.fitKey != widget.fitKey || gotFirstFix) {
      _userMoved = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => fit());
    } else if (widget.follow != null &&
        widget.follow != old.follow &&
        !_userMoved) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _followNow());
    }
    // Novo ponto do motorista: desliza a partir de onde o marcador está agora.
    if (widget.driver != old.driver) {
      if (widget.driver == null ||
          _driverShown == null ||
          MediaQuery.disableAnimationsOf(context)) {
        _driverShown = widget.driver;
      } else {
        _driverFrom = _driverShown;
        _glide.forward(from: 0);
      }
    }
  }

  void fit() {
    if (!_ready || !mounted) return;
    final points = <LatLng>[
      ?widget.pickup,
      ?widget.dropoff,
      ?widget.driver,
      ?widget.alert,
      if (widget.meIsCar) ?widget.me,
      ...widget.route,
      ...widget.tripRoute,
    ];
    if (points.length >= 2) {
      _controller.fitCamera(
        CameraFit.coordinates(
          coordinates: points,
          maxZoom: 17,
          padding: EdgeInsets.fromLTRB(48, 120, 48, widget.bottomPadding + 48),
        ),
      );
    } else {
      final target = points.isNotEmpty ? points.first : widget.me;
      if (target != null) _controller.move(target, 16);
    }
  }

  /// Marcador de um ponto da corrida; com [BazaMap.labels], leva o nome por cima.
  Marker _place(
    LatLng point,
    String label,
    IconData icon,
    Color color, {
    double size = 34,
  }) {
    final pin = SizedBox.square(
      dimension: size,
      child: _Pin(icon: icon, color: color),
    );
    if (!widget.labels) {
      return Marker(point: point, width: size, height: size, child: pin);
    }
    // Altura simétrica em torno do ponto: etiqueta em cima, espaço igual em baixo.
    const tag = 24.0;
    return Marker(
      point: point,
      width: 110,
      height: size + 2 * tag,
      child: Column(
        children: [
          SizedBox(
            height: tag,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 4),
                  ],
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ),
            ),
          ),
          pin,
        ],
      ),
    );
  }

  @override
  void dispose() {
    _placesTimer?.cancel();
    _glide.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      mapController: _controller,
      options: MapOptions(
        initialCenter: widget.me ?? widget.pickup ?? defaultCenter,
        initialZoom: 15,
        minZoom: 3,
        maxZoom: 19,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        onPositionChanged: (camera, hasGesture) {
          if (hasGesture && !_userMoved) setState(() => _userMoved = true);
          _schedulePlaces();
        },
        onMapReady: () {
          _ready = true;
          fit();
          _schedulePlaces();
        },
      ),
      children: [
        TileLayer(
          urlTemplate: tileUrlTemplate,
          userAgentPackageName: 'ao.baza.baza',
          maxNativeZoom: 19,
        ),
        if (widget.route.length >= 2 || widget.tripRoute.length >= 2)
          PolylineLayer(
            polylines: [
              if (widget.tripRoute.length >= 2)
                Polyline(
                  points: widget.tripRoute,
                  strokeWidth: 4,
                  color: BazaColors.ink.withValues(alpha: 0.35),
                ),
              if (widget.route.length >= 2)
                Polyline(
                  points: widget.route,
                  strokeWidth: 5,
                  color: BazaColors.ink,
                ),
            ],
          ),
        if (_places.isNotEmpty)
          MarkerLayer(
            markers: [
              for (final p in _places)
                Marker(
                  point: p.point,
                  width: 150,
                  height: 44,
                  // O ponto fica exactamente sobre o local; o nome por baixo.
                  alignment: Alignment.center,
                  child: IgnorePointer(child: _PlaceTag(name: p.name)),
                ),
            ],
          ),
        MarkerLayer(
          markers: [
            if (widget.me != null && !widget.meIsCar)
              Marker(
                point: widget.me!,
                width: 22,
                height: 22,
                child: const _MeDot(),
              ),
            if (widget.pickup != null)
              _place(
                widget.pickup!,
                'Recolha',
                Icons.person_pin_circle,
                BazaColors.green,
              ),
            for (final (i, stop) in widget.stops.indexed)
              _place(
                stop,
                'Paragem ${i + 1}',
                Icons.stop_circle_outlined,
                const Color(0xFFB45309),
                size: 26,
              ),
            if (widget.dropoff != null)
              _place(widget.dropoff!, 'Destino', Icons.flag, BazaColors.red),
            if (widget.alert != null)
              _place(
                widget.alert!,
                'Alerta',
                Icons.warning_amber_rounded,
                const Color(0xFF7F1D1D),
                size: 30,
              ),
            if (widget.me != null && widget.meIsCar)
              Marker(
                point: widget.me!,
                width: 40,
                height: 40,
                child: const _Pin(
                  icon: Icons.local_taxi,
                  color: BazaColors.ink,
                  big: true,
                ),
              ),
            if (widget.driver != null)
              Marker(
                point: _driverShown ?? widget.driver!,
                width: 40,
                height: 40,
                // Com os dados da viatura, o marcador mostra o tipo e a cor dela.
                child: widget.driverVehicle != null
                    ? DecoratedBox(
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(color: Colors.black38, blurRadius: 6),
                          ],
                        ),
                        child: VehicleBadge(
                          vehicle: widget.driverVehicle!,
                          size: 40,
                        ),
                      )
                    : const _Pin(
                        icon: Icons.local_taxi,
                        color: BazaColors.ink,
                        big: true,
                      ),
              ),
          ],
        ),
        if (_userMoved)
          Positioned(
            right: 12,
            bottom: widget.bottomPadding + 16,
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: widget.follow != null
                  ? 'Voltar a seguir o carro'
                  : 'Recentrar o mapa',
              backgroundColor: Colors.white,
              foregroundColor: BazaColors.ink,
              onPressed: recenter,
              child: const Icon(Icons.my_location),
            ),
          ),
        // Créditos do mapa: a licença dos dados (OpenStreetMap) obriga a
        // indicá-los. Ficam atrás de um botão discreto, para não ocupar o mapa.
        Align(
          alignment: Alignment.topRight,
          child: SafeArea(
            child: Padding(
              // Por baixo do botão de menu, no canto superior direito.
              padding: const EdgeInsets.fromLTRB(6, 64, 14, 6),
              child: Semantics(
                button: true,
                label: 'Créditos do mapa',
                child: GestureDetector(
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Créditos do mapa'),
                      content: Text(
                        ownTiles
                            ? 'Dados do mapa © contribuidores do OpenStreetMap (openstreetmap.org/copyright). Desenho do mapa: Protomaps.'
                            : 'Mapa © contribuidores do OpenStreetMap (openstreetmap.org/copyright).',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Fechar'),
                        ),
                      ],
                    ),
                  ),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.75),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.info_outline,
                      size: 16,
                      color: BazaColors.muted,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MeDot extends StatelessWidget {
  const _MeDot();
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: const Color(0xFF2563EB),
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 3),
      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
    ),
  );
}

class _Pin extends StatelessWidget {
  const _Pin({required this.icon, required this.color, this.big = false});
  final IconData icon;
  final Color color;
  final bool big;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: big ? BazaColors.yellow : Colors.white,
      shape: BoxShape.circle,
      boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 6)],
    ),
    child: Icon(icon, color: color, size: big ? 24 : 22),
  );
}

/// Local registado no Bazá: um ponto amarelo com o nome por baixo.
class _PlaceTag extends StatelessWidget {
  const _PlaceTag({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    alignment: Alignment.center,
    children: [
      Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: BazaColors.yellow,
          shape: BoxShape.circle,
          border: Border.all(color: BazaColors.ink, width: 1.5),
        ),
      ),
      Positioned(
        top: 30,
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: BazaColors.ink,
            height: 1,
            shadows: [
              Shadow(color: Colors.white, blurRadius: 3),
              Shadow(color: Colors.white, blurRadius: 3),
              Shadow(color: Colors.white, blurRadius: 3),
            ],
          ),
        ),
      ),
    ],
  );
}
