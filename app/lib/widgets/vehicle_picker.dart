import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/theme.dart';

/// Escolha da viatura ao pedir uma corrida: cartões lado a lado, a deslizar
/// na horizontal, cada um com o desenho da viatura, o tempo até chegar o carro
/// mais próximo, o nome e o preço. O escolhido fica com fundo cinzento.
class VehicleCarousel extends StatelessWidget {
  const VehicleCarousel({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelect,
    this.onNegotiated,
  });

  final List<FareOption> options;
  final String selected;
  final ValueChanged<String> onSelect;

  /// Se dado, acrescenta no fim o cartão «A combinar» (triciclo, XL, carrinha
  /// ou camião, com preço combinado com o motorista).
  final VoidCallback? onNegotiated;

  @override
  Widget build(BuildContext context) {
    // O mais rápido a chegar leva o tempo num selo verde.
    final etas = [for (final o in options) ?o.etaS];
    final fastest = etas.isEmpty ? null : etas.reduce((a, b) => a < b ? a : b);
    return SizedBox(
      height: 140,
      child: ListView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        children: [
          for (final o in options)
            VehicleCard(
              category: o.category,
              label: o.label,
              price: kz(o.fare),
              etaS: o.etaS,
              fastest: o.etaS != null && o.etaS == fastest && options.length > 1,
              selected: o.category == selected,
              onTap: () => onSelect(o.category),
            ),
          if (onNegotiated != null)
            VehicleCard(
              category: 'pickup',
              label: 'Triciclo, XL…',
              price: 'A combinar',
              selected: false,
              onTap: onNegotiated!,
            ),
        ],
      ),
    );
  }
}

class VehicleCard extends StatelessWidget {
  const VehicleCard({
    super.key,
    required this.category,
    required this.label,
    required this.price,
    required this.selected,
    required this.onTap,
    this.etaS,
    this.fastest = false,
  });

  final String category, label, price;
  final int? etaS;
  final bool fastest, selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final eta = etaS == null ? null : '${(etaS! / 60).ceil()} min';
    return Semantics(
      button: true,
      selected: selected,
      label: [label, price, if (eta != null) 'chega em $eta'].join(', '),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Material(
          color: selected ? BazaColors.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: SizedBox(
              width: 112,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 58,
                      width: double.infinity,
                      child: Stack(
                        children: [
                          // O desenho fica por cima; os minutos, por baixo e à esquerda.
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 0,
                            height: 46,
                            child: CustomPaint(
                              painter: VehicleArt(category),
                            ),
                          ),
                          if (eta != null)
                            Positioned(
                              left: 0,
                              bottom: 0,
                              child: _EtaTag(text: eta, highlight: fastest),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected ? BazaColors.ink : BazaColors.muted,
                      ),
                    ),
                    Text(
                      price,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: selected ? BazaColors.ink : const Color(0xFF374151),
                      ),
                    ),
                    if (etaS == null && price != 'A combinar')
                      const Text(
                        'Sem carros perto',
                        maxLines: 1,
                        style: TextStyle(fontSize: 11.5, color: BazaColors.muted),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EtaTag extends StatelessWidget {
  const _EtaTag({required this.text, required this.highlight});
  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: highlight ? BazaColors.green : Colors.white,
      borderRadius: BorderRadius.circular(6),
      boxShadow: highlight
          ? null
          : const [BoxShadow(color: Color(0x22000000), blurRadius: 3)],
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        color: highlight ? Colors.white : BazaColors.ink,
      ),
    ),
  );
}

/// Desenho simples da viatura, de lado e virada para a direita, por tipo de
/// serviço. Feito à mão (sem imagens), escala com o espaço disponível.
class VehicleArt extends CustomPainter {
  const VehicleArt(this.category);
  final String category;

  static const _glass = Color(0xFF2E3A48);
  static const _tyre = Color(0xFF1F2328);
  static const _outline = Color(0x40000000);

  /// Cor da carroçaria de cada tipo.
  static const colors = {
    'moto': Color(0xFFE5484D),
    'tricycle': Color(0xFF22A06B),
    'economy': Color(0xFFF2F4F7),
    'comfort': Color(0xFF6B7684),
    'xl': Color(0xFFF2F4F7),
    'delivery': Color(0xFFF97316),
    'cargo_tricycle': Color(0xFF2F6FDB),
    'pickup': Color(0xFFF2F4F7),
    'truck': Color(0xFFF2F4F7),
  };

  @override
  void paint(Canvas canvas, Size size) {
    // Desenha numa caixa de 100×50, centrada e à escala.
    final k = (size.width / 100).clamp(0.0, size.height / 50);
    canvas
      ..save()
      ..translate((size.width - 100 * k) / 2, (size.height - 50 * k) / 2)
      ..scale(k);
    final body = colors[category] ?? colors['economy']!;
    // Sombra no chão.
    canvas.drawOval(
      const Rect.fromLTRB(6, 41, 94, 47),
      Paint()..color = const Color(0x1A000000),
    );
    switch (category) {
      case 'moto':
        _moto(canvas, body);
      case 'delivery':
        _moto(canvas, body, box: true);
      case 'tricycle':
        _tricycle(canvas, body);
      case 'cargo_tricycle':
        _tricycle(canvas, body, cargo: true);
      case 'comfort':
        _sedan(canvas, body, long: true);
      case 'xl':
        _van(canvas, body);
      case 'pickup':
        _pickup(canvas, body);
      case 'truck':
        _truck(canvas, body);
      default:
        _sedan(canvas, body);
    }
    canvas.restore();
  }

  Paint _fill(Color c) => Paint()..color = c;
  Paint get _line => Paint()
    ..color = _outline
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;

  void _wheel(Canvas c, double x, double y, double r) {
    c.drawCircle(Offset(x, y), r, _fill(_tyre));
    c.drawCircle(Offset(x, y), r * 0.45, _fill(const Color(0xFFB8C0CA)));
  }

  void _shape(Canvas c, Path p, Color color) {
    c
      ..drawPath(p, _fill(color))
      ..drawPath(p, _line);
  }

  void _sedan(Canvas c, Color body, {bool long = false}) {
    final roofL = long ? 33.0 : 35.0, roofR = long ? 66.0 : 63.0;
    final cabin = Path()
      ..moveTo(20, 27)
      ..lineTo(roofL, 14)
      ..lineTo(roofR, 14)
      ..lineTo(long ? 80 : 77, 27)
      ..close();
    final lower = Path()
      ..addRRect(
        RRect.fromLTRBAndCorners(
          5,
          25,
          95,
          38,
          topLeft: const Radius.circular(6),
          topRight: const Radius.circular(10),
          bottomLeft: const Radius.circular(4),
          bottomRight: const Radius.circular(4),
        ),
      );
    _shape(c, cabin, body);
    _shape(c, lower, body);
    final mid = (roofL + roofR) / 2;
    c
      ..drawPath(
        Path()
          ..moveTo(25, 26)
          ..lineTo(roofL + 2, 16.5)
          ..lineTo(mid - 1, 16.5)
          ..lineTo(mid - 1, 26)
          ..close(),
        _fill(_glass),
      )
      ..drawPath(
        Path()
          ..moveTo(mid + 1, 26)
          ..lineTo(mid + 1, 16.5)
          ..lineTo(roofR - 1, 16.5)
          ..lineTo(long ? 74 : 71.5, 26)
          ..close(),
        _fill(_glass),
      )
      // Farol e luz de trás.
      ..drawRRect(
        RRect.fromLTRBR(89, 28, 94, 31, const Radius.circular(1.5)),
        _fill(const Color(0xFFFFE08A)),
      )
      ..drawRRect(
        RRect.fromLTRBR(6, 28, 9, 31, const Radius.circular(1.5)),
        _fill(const Color(0xFFE5484D)),
      );
    _wheel(c, 25, 38, 7);
    _wheel(c, 75, 38, 7);
  }

  void _van(Canvas c, Color body) {
    final p = Path()
      ..moveTo(5, 38)
      ..lineTo(5, 15)
      ..quadraticBezierTo(5, 11, 10, 11)
      ..lineTo(68, 11)
      ..lineTo(86, 24)
      ..quadraticBezierTo(95, 26, 95, 31)
      ..lineTo(95, 38)
      ..close();
    _shape(c, p, body);
    for (final x in [10.0, 30.0, 50.0]) {
      c.drawRRect(
        RRect.fromLTRBR(x, 15, x + 17, 24, const Radius.circular(2)),
        _fill(_glass),
      );
    }
    c.drawPath(
      Path()
        ..moveTo(70, 15)
        ..lineTo(82, 24)
        ..lineTo(70, 24)
        ..close(),
      _fill(_glass),
    );
    _wheel(c, 24, 38, 7);
    _wheel(c, 77, 38, 7);
  }

  void _pickup(Canvas c, Color body) {
    final lower = Path()
      ..addRRect(RRect.fromLTRBR(5, 24, 95, 37, const Radius.circular(4)));
    final cab = Path()
      ..moveTo(50, 25)
      ..lineTo(54, 11)
      ..lineTo(72, 11)
      ..lineTo(84, 25)
      ..close();
    _shape(c, cab, body);
    _shape(c, lower, body);
    c
      ..drawPath(
        Path()
          ..moveTo(57, 23.5)
          ..lineTo(59, 14)
          ..lineTo(70.5, 14)
          ..lineTo(79, 23.5)
          ..close(),
        _fill(_glass),
      )
      // Caixa aberta atrás.
      ..drawLine(const Offset(8, 27), const Offset(46, 27), _line);
    _wheel(c, 23, 37, 7);
    _wheel(c, 77, 37, 7);
  }

  void _truck(Canvas c, Color body) {
    _shape(
      c,
      Path()..addRRect(RRect.fromLTRBR(3, 5, 65, 34, const Radius.circular(3))),
      const Color(0xFFFFC400),
    );
    final cab = Path()
      ..moveTo(67, 34)
      ..lineTo(67, 13)
      ..lineTo(84, 13)
      ..lineTo(96, 24)
      ..lineTo(96, 34)
      ..close();
    _shape(c, cab, body);
    c.drawPath(
      Path()
        ..moveTo(71, 16)
        ..lineTo(83, 16)
        ..lineTo(91, 23.5)
        ..lineTo(71, 23.5)
        ..close(),
      _fill(_glass),
    );
    _wheel(c, 17, 38, 6.5);
    _wheel(c, 52, 38, 6.5);
    _wheel(c, 84, 38, 6.5);
  }

  void _moto(Canvas c, Color body, {bool box = false}) {
    if (box) {
      _shape(
        c,
        Path()..addRRect(RRect.fromLTRBR(10, 8, 36, 27, const Radius.circular(3))),
        const Color(0xFFFFC400),
      );
    }
    final frame = Path()
      ..moveTo(26, 31)
      ..lineTo(34, 21)
      ..lineTo(60, 21)
      ..lineTo(70, 27)
      ..lineTo(58, 33)
      ..close();
    _shape(c, frame, body);
    // Assento, guiador e garfo.
    c
      ..drawRRect(
        RRect.fromLTRBR(36, 17.5, 56, 21.5, const Radius.circular(2)),
        _fill(_tyre),
      )
      ..drawLine(
        const Offset(68, 26),
        const Offset(79, 37),
        Paint()
          ..color = _tyre
          ..strokeWidth = 2.5,
      )
      ..drawLine(
        const Offset(66, 14),
        const Offset(70, 27),
        Paint()
          ..color = _tyre
          ..strokeWidth = 2.5,
      )
      ..drawLine(
        const Offset(62, 13),
        const Offset(70, 14),
        Paint()
          ..color = _tyre
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round,
      );
    _wheel(c, 22, 37, 8.5);
    _wheel(c, 79, 37, 8.5);
  }

  void _tricycle(Canvas c, Color body, {bool cargo = false}) {
    if (cargo) {
      _shape(
        c,
        Path()..addRRect(RRect.fromLTRBR(5, 17, 52, 33, const Radius.circular(2))),
        body,
      );
    } else {
      final cabin = Path()
        ..moveTo(6, 33)
        ..lineTo(6, 14)
        ..quadraticBezierTo(6, 8, 14, 8)
        ..lineTo(48, 8)
        ..quadraticBezierTo(56, 8, 58, 16)
        ..lineTo(60, 33)
        ..close();
      _shape(c, cabin, body);
      c.drawRRect(
        RRect.fromLTRBR(12, 13, 50, 22, const Radius.circular(2)),
        _fill(_glass),
      );
    }
    // Frente da moto.
    c
      ..drawPath(
        Path()
          ..moveTo(54, 33)
          ..lineTo(62, 22)
          ..lineTo(72, 22)
          ..lineTo(76, 30)
          ..close(),
        _fill(cargo ? const Color(0xFF374151) : body),
      )
      ..drawLine(
        const Offset(72, 22),
        const Offset(82, 37),
        Paint()
          ..color = _tyre
          ..strokeWidth = 2.5,
      );
    _wheel(c, 26, 37, 7);
    _wheel(c, 82, 37, 7);
  }

  @override
  bool shouldRepaint(VehicleArt old) => old.category != category;
}

/// Hora de chegada ao destino ("8:38"), a partir de agora + tempo até o carro
/// chegar + duração da viagem.
String arrivalClock(int travelS, {int? waitS}) {
  final t = DateTime.now().add(Duration(seconds: travelS + (waitS ?? 0)));
  return '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
}
