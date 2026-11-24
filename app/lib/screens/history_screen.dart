import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../state/session.dart';
import '../widgets/common.dart';
import 'support_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.asDriver});
  final bool asDriver;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Ride>? _rides;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await context.read<Session>().api.get('/rides/history', {
        'role': widget.asDriver ? 'driver' : 'passenger',
      });
      final rides = [
        for (final r in res['rides'] as List)
          Ride.fromJson(Map<String, dynamic>.from(r as Map)),
      ];
      if (mounted) {
        setState(() {
          _rides = rides;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rides = _rides;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.asDriver ? 'Corridas como motorista' : 'As minhas corridas',
        ),
      ),
      body: rides == null
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
          : rides.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Ainda não tem corridas. As suas viagens aparecem aqui.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: BazaColors.muted, fontSize: 16),
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: rides.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) => _tile(rides[i]),
              ),
            ),
    );
  }

  Widget _tile(Ride ride) {
    final cancelled = ride.status == 'cancelled';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BazaColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  dateTime(ride.createdAt),
                  style: const TextStyle(color: BazaColors.muted, fontSize: 13),
                ),
              ),
              Text(
                cancelled ? 'Cancelada' : kz(ride.fare),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: cancelled ? BazaColors.red : BazaColors.ink,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          RouteSummary(
            pickup: ride.pickup.address,
            dropoff: ride.dropoff.address,
            stops: [for (final s in ride.stops) s.address],
          ),
          if (!cancelled)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '${categoryLabels[ride.category] ?? ride.category} · ${paymentLabels[ride.paymentMethod] ?? ''} · ${km(ride.distanceM)}',
                style: const TextStyle(color: BazaColors.muted, fontSize: 13),
              ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (!cancelled)
                TextButton.icon(
                  onPressed: () => _receipt(ride),
                  icon: const Icon(Icons.receipt_long_outlined, size: 18),
                  label: const Text('Recibo'),
                ),
              TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => SupportScreen(ride: ride)),
                ),
                icon: const Icon(Icons.help_outline, size: 18),
                label: const Text('Reportar problema'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Texto do recibo, para mostrar e partilhar.
  String _receiptText(Ride ride) {
    final other = widget.asDriver ? ride.passenger : ride.driver;
    return [
      'Bazá · Recibo da corrida',
      'Data: ${dateTime(ride.createdAt)}',
      'De: ${ride.pickup.address}',
      for (final (i, s) in ride.stops.indexed) 'Paragem ${i + 1}: ${s.address}',
      'Para: ${ride.dropoff.address}',
      'Distância: ${km(ride.distanceM)}',
      'Serviço: ${categoryLabels[ride.category] ?? ride.category}',
      if (other != null)
        '${widget.asDriver ? 'Passageiro' : 'Motorista'}: ${other.name}',
      'Pagamento: ${paymentLabels[ride.paymentMethod] ?? ride.paymentMethod}',
      'Total: ${kz(ride.fare)}',
      'Referência: ${ride.id.substring(ride.id.length - 8).toUpperCase()}',
    ].join('\n');
  }

  void _receipt(Ride ride) {
    final text = _receiptText(ride);
    showModalBottomSheet<void>(
      isDismissible: false,
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Recibo da corrida',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              for (final line in text.split('\n').skip(1))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text(
                    line,
                    style: TextStyle(
                      fontWeight: line.startsWith('Total')
                          ? FontWeight.w800
                          : FontWeight.w400,
                      fontSize: line.startsWith('Total') ? 17 : 14,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => SharePlus.instance.share(
                    ShareParams(text: text, subject: 'Recibo Bazá'),
                  ),
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('Partilhar recibo'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
