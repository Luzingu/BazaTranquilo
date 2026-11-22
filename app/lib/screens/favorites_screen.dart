import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../state/session.dart';
import '../widgets/common.dart';

/// Carrega os motoristas preferidos do passageiro, com a disponibilidade actual.
Future<List<FavoriteDriver>> loadFavorites(
  ApiClient api, {
  LatLng? near,
}) async {
  final res = await api.get('/favorites', {
    if (near != null) 'lat': '${near.latitude}',
    if (near != null) 'lng': '${near.longitude}',
  });
  return [
    for (final d in res['drivers'] as List)
      FavoriteDriver.fromJson(Map<String, dynamic>.from(d as Map)),
  ];
}

String favoriteStatus(FavoriteDriver f) {
  if (!f.available) return 'Indisponível agora';
  return f.distanceM == null
      ? 'Disponível'
      : 'Disponível · a ${km(f.distanceM!)}';
}

/// Linha com foto, nome, viatura e disponibilidade de um motorista preferido.
class FavoriteTile extends StatelessWidget {
  const FavoriteTile({
    super.key,
    required this.favorite,
    this.onTap,
    this.trailing,
  });
  final FavoriteDriver favorite;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final d = favorite.driver;
    final v = d.vehicle;
    return ListTile(
      enabled: onTap != null || trailing != null,
      onTap: onTap,
      leading: Avatar(name: d.name, photoUrl: d.photoUrl, radius: 22),
      title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (v != null)
            Text(
              '${categoryLabels[v.category] ?? ''} · ${v.description} · ${v.plate}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          Row(
            children: [
              Icon(
                Icons.circle,
                size: 9,
                color: favorite.available
                    ? BazaColors.green
                    : const Color(0xFF9CA3AF),
              ),
              const SizedBox(width: 6),
              Text(
                favoriteStatus(favorite),
                style: TextStyle(
                  color: favorite.available
                      ? BazaColors.green
                      : BazaColors.muted,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ],
      ),
      trailing: trailing,
    );
  }
}

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  List<FavoriteDriver>? _favorites;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await loadFavorites(context.read<Session>().api);
      if (mounted) {
        setState(() {
          _favorites = list;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _remove(FavoriteDriver f) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remover ${f.driver.name} dos preferidos?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Não'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await context.read<Session>().api.delete('/favorites/${f.driver.id}');
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _favorites;
    return Scaffold(
      appBar: AppBar(title: const Text('Motoristas preferidos')),
      body: list == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator(color: BazaColors.ink)
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!),
                        TextButton(
                          onPressed: _load,
                          child: const Text('Tentar novamente'),
                        ),
                      ],
                    ),
            )
          : list.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Ainda não tem motoristas preferidos.\n\nNo fim de uma corrida, toque em "Adicionar aos preferidos" para poder chamar esse motorista directamente.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: BazaColors.muted, fontSize: 16),
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text(
                      'Ao pedir uma corrida pode chamar primeiro um destes motoristas, se estiver disponível.',
                      style: TextStyle(color: BazaColors.muted),
                    ),
                  ),
                  for (final f in list)
                    FavoriteTile(
                      favorite: f,
                      trailing: IconButton(
                        tooltip: 'Remover dos preferidos',
                        icon: const Icon(Icons.favorite, color: BazaColors.red),
                        onPressed: () => _remove(f),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
