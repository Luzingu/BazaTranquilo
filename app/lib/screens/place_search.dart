import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../core/format.dart';
import '../core/location.dart';
import '../state/session.dart';
import 'saved_places_screen.dart';

class _Suggestion {
  _Suggestion(Map<String, dynamic> j)
    : place = Place.fromJson(j),
      title = j['title'] as String? ?? j['address'] as String,
      subtitle = j['subtitle'] as String? ?? '';
  final Place place;
  final String title, subtitle;
}

/// Pesquisa de endereços com sugestões enquanto se escreve.
/// Devolve o [Place] escolhido com Navigator.pop.
class PlaceSearchScreen extends StatefulWidget {
  const PlaceSearchScreen({
    super.key,
    required this.title,
    this.near,
    this.showSaved = true,
    this.offerCurrentLocation = false,
  });
  final String title;
  final LatLng? near;

  /// Mostrar a opção "Localização actual" (ao escolher o ponto de recolha).
  final bool offerCurrentLocation;

  /// Mostrar os locais guardados (Casa, Trabalho, …) antes de se escrever.
  /// Desligado quando se está precisamente a escolher o endereço de um deles.
  final bool showSaved;

  @override
  State<PlaceSearchScreen> createState() => _PlaceSearchScreenState();
}

class _PlaceSearchScreenState extends State<PlaceSearchScreen> {
  final _input = TextEditingController();
  Timer? _debounce;
  List<_Suggestion> _recent = [];
  List<SavedPlace> _saved = [];
  List<_Suggestion> _results = [];
  String _query = '';
  bool _loading = false;
  String? _error;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _loadRecent();
    if (widget.showSaved) _loadSaved();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    super.dispose();
  }

  List<_Suggestion> _parse(Map<String, dynamic> res) => [
    for (final p in res['places'] as List)
      _Suggestion(Map<String, dynamic>.from(p as Map)),
  ];

  Future<void> _loadRecent() async {
    try {
      final recent = _parse(
        await context.read<Session>().api.get('/places/recent'),
      );
      if (mounted) setState(() => _recent = recent);
    } on ApiException {
      // Os recentes são apenas uma ajuda; sem eles o ecrã funciona na mesma.
    }
  }

  Future<void> _loadSaved() async {
    try {
      final saved = await loadSavedPlaces(context.read<Session>().api);
      if (mounted) setState(() => _saved = saved);
    } on ApiException {
      // Sem os locais guardados o ecrã funciona na mesma.
    }
  }

  /// Guarda Casa/Trabalho/outro e usa logo esse local.
  Future<void> _addSaved(String kind) async {
    final navigator = Navigator.of(context);
    try {
      final before = {for (final p in _saved) p.id};
      final saved = await addSavedPlace(context, kind: kind, near: widget.near);
      if (saved == null || !mounted) return;
      final added = saved
          .where(
            (p) =>
                p.kind == kind && (kind != 'other' || !before.contains(p.id)),
          )
          .firstOrNull;
      if (added != null) {
        navigator.pop(added.place);
      } else {
        setState(() => _saved = saved);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Casa e Trabalho (ou o convite para os definir) e os outros locais guardados.
  List<Widget> _savedTiles() {
    Widget tile(
      IconData icon,
      String title,
      String? subtitle,
      VoidCallback onTap, {
      bool filled = true,
    }) => ListTile(
      leading: CircleAvatar(
        backgroundColor: filled
            ? BazaColors.yellow.withValues(alpha: 0.25)
            : BazaColors.surface,
        foregroundColor: filled ? BazaColors.ink : BazaColors.muted,
        child: Icon(icon, size: 20),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: filled ? null : const Icon(Icons.add, color: BazaColors.muted),
      onTap: onTap,
    );
    return [
      for (final (kind, label, icon) in const [
        ('home', 'Casa', Icons.home_outlined),
        ('work', 'Trabalho', Icons.work_outline),
      ])
        if (_saved.where((p) => p.kind == kind).firstOrNull case final p?)
          tile(
            p.icon,
            p.label,
            p.place.address,
            () => Navigator.of(context).pop(p.place),
          )
        else
          tile(
            icon,
            'Adicionar $label',
            null,
            () => _addSaved(kind),
            filled: false,
          ),
      for (final p in _saved.where((p) => p.kind == 'other'))
        tile(
          p.icon,
          p.label,
          p.place.address,
          () => Navigator.of(context).pop(p.place),
        ),
      tile(
        Icons.bookmark_add_outlined,
        'Guardar outro local',
        null,
        () => _addSaved('other'),
        filled: false,
      ),
      const Divider(height: 16),
    ];
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    final q = text.trim();
    if (q == _query) return;
    _requestId++; // invalida respostas de pesquisas anteriores
    setState(() {
      _query = q;
      _error = null;
      _loading = q.length >= 2;
      if (q.length < 2) _results = [];
    });
    // Uma só letra devolve resultados sem sentido; espera pela segunda.
    if (q.length < 2) return;
    // Pausa curta: sugere quase a cada tecla sem fazer um pedido por letra.
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(q));
  }

  Future<void> _search(String q) async {
    final id = _requestId;
    final api = context.read<Session>().api;
    try {
      final res = await api.get('/places/search', {
        'q': q,
        if (widget.near != null) 'lat': '${widget.near!.latitude}',
        if (widget.near != null) 'lng': '${widget.near!.longitude}',
      });
      if (!mounted || id != _requestId) return;
      setState(() {
        _results = _parse(res);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  bool _locating = false;

  /// Devolve o sítio onde o utilizador está agora, já com a morada.
  Future<void> _useCurrentLocation() async {
    final api = context.read<Session>().api;
    final navigator = Navigator.of(context);
    setState(() => _locating = true);
    try {
      final here = await currentLatLng();
      if (here == null)
        throw locationProblem ?? 'Não foi possível obter a sua posição.';
      Place place;
      try {
        final res = await api.get('/places/reverse', {
          'lat': '${here.latitude}',
          'lng': '${here.longitude}',
        });
        place = Place.fromJson(res['place'] as Map<String, dynamic>);
      } on ApiException {
        place = Place(
          address: 'Localização actual',
          lat: here.latitude,
          lng: here.longitude,
        );
      }
      navigator.pop(place);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showingRecent = _query.isEmpty;
    final items = showingRecent ? _recent : _results;

    final saved = showingRecent && widget.showSaved
        ? _savedTiles()
        : const <Widget>[];
    String? message;
    if (showingRecent && items.isEmpty && saved.isEmpty) {
      message = widget.offerCurrentLocation
          ? 'Ou comece a escrever e escolha uma das sugestões.'
          : 'Comece a escrever e escolha uma das sugestões.';
    } else if (!showingRecent && !_loading && items.isEmpty) {
      message = _query.length < 2
          ? 'Continue a escrever…'
          : _error ?? 'Nenhum local encontrado para "$_query".';
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _input,
              autofocus: true,
              autocorrect: false,
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              decoration: InputDecoration(
                hintText: 'Rua, bairro ou local',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Limpar',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _input.clear();
                          _onChanged('');
                        },
                      ),
              ),
            ),
          ),
          SizedBox(
            height: 2,
            child: _loading
                ? const LinearProgressIndicator(
                    color: BazaColors.ink,
                    minHeight: 2,
                  )
                : null,
          ),
          if (widget.offerCurrentLocation && _query.isEmpty)
            ListTile(
              leading: const CircleAvatar(
                backgroundColor: BazaColors.ink,
                foregroundColor: BazaColors.yellow,
                child: Icon(Icons.my_location, size: 20),
              ),
              title: const Text(
                'Localização actual',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                _locating
                    ? 'A obter a sua posição…'
                    : 'Recolher onde estou agora',
              ),
              trailing: _locating
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: BazaColors.ink,
                      ),
                    )
                  : null,
              onTap: _locating ? null : _useCurrentLocation,
            ),
          Expanded(
            child: message != null
                ? Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        message,
                        style: const TextStyle(color: BazaColors.muted),
                      ),
                    ),
                  )
                : ListView.builder(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    // Primeiro os locais guardados, depois os recentes (ou as sugestões).
                    itemCount:
                        saved.length +
                        (items.isEmpty
                            ? 0
                            : items.length + (showingRecent ? 1 : 0)),
                    itemBuilder: (context, index) {
                      if (index < saved.length) return saved[index];
                      final i = index - saved.length;
                      if (showingRecent && i == 0) {
                        return const Padding(
                          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text(
                            'Destinos recentes',
                            style: TextStyle(
                              color: BazaColors.muted,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        );
                      }
                      final s = items[showingRecent ? i - 1 : i];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: BazaColors.surface,
                          foregroundColor: BazaColors.ink,
                          child: Icon(
                            showingRecent
                                ? Icons.history
                                : Icons.place_outlined,
                            size: 20,
                          ),
                        ),
                        title: _Highlighted(text: s.title, query: _query),
                        subtitle: s.subtitle.isEmpty
                            ? null
                            : Text(
                                s.subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                        onTap: () => Navigator.of(context).pop(s.place),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Mostra o texto com a parte que coincide com a pesquisa a negrito.
class _Highlighted extends StatelessWidget {
  const _Highlighted({required this.text, required this.query});
  final String text, query;

  @override
  Widget build(BuildContext context) {
    final start = query.isEmpty
        ? -1
        : text.toLowerCase().indexOf(query.toLowerCase());
    const base = TextStyle(fontSize: 16, color: BazaColors.ink);
    if (start < 0 || start + query.length > text.length) {
      return Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }
    final end = start + query.length;
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: text.substring(0, start)),
          TextSpan(
            text: text.substring(start, end),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          TextSpan(text: text.substring(end)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
