import 'package:flutter/material.dart';

import 'api.dart';

import 'package:latlong2/latlong.dart';

/// 4850 → "4 850 Kz"
String kz(int amount) {
  final digits = amount.abs().toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(' ');
    out.write(digits[i]);
  }
  return '${amount < 0 ? '−' : ''}$out Kz';
}

String km(int meters) => meters < 1000
    ? '$meters m'
    : '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';

String minutes(int seconds) => '${(seconds / 60).ceil()} min';

String dateOnly(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year}';
}

/// "21/11/2026"
String date(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

String dateTime(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} · ${two(d.hour)}:${two(d.minute)}';
}

const paymentLabels = {
  'corporate': 'Conta da empresa',
  'cash': 'Dinheiro',
  'wallet': 'Carteira Bazá',
  'multicaixa': 'Multicaixa Express',
};
const paymentIcons = {
  'corporate': Icons.business_center_outlined,
  'cash': Icons.payments_outlined,
  'wallet': Icons.account_balance_wallet_outlined,
  'multicaixa': Icons.credit_card,
};
// Categorias de viatura / serviço. As chaves têm de coincidir com o catálogo
// do servidor (backend/src/config.ts).
const categoryLabels = {
  'moto': 'Moto',
  'tricycle': 'Triciclo',
  'economy': 'Económico',
  'comfort': 'Conforto',
  'xl': 'XL',
  'delivery': 'Entrega',
  'cargo_tricycle': 'Triciclo de carga (Kupapata)',
  'pickup': 'Carrinha',
  'truck': 'Camião',
};
const categoryIcons = {
  'moto': Icons.two_wheeler,
  'tricycle': Icons.electric_rickshaw,
  'economy': Icons.directions_car_filled_outlined,
  'comfort': Icons.time_to_leave,
  'xl': Icons.airport_shuttle_outlined,
  'delivery': Icons.delivery_dining,
  'cargo_tricycle': Icons.electric_rickshaw_outlined,
  'pickup': Icons.local_shipping_outlined,
  'truck': Icons.local_shipping,
};

/// O que o motorista faz com cada tipo de viatura (para o registo da viatura).
const categoryHints = {
  'moto': 'Transporta 1 passageiro',
  'tricycle': 'Moto de 3 rodas, até 3 passageiros',
  'economy': 'Carro ligeiro, 4 passageiros',
  'comfort': 'Carro espaçoso com ar condicionado',
  'xl': 'Carrinha de passageiros, até 6 lugares',
  'delivery': 'Moto para entregar encomendas até 20 kg',
  'cargo_tricycle': 'Moto de 3 rodas com caixa, até 500 kg',
  'pickup': 'Caixa aberta ou furgão, até 1,5 t',
  'truck': 'Mudanças e cargas grandes, até 8 t',
};
const passengerCategories = ['moto', 'tricycle', 'economy', 'comfort', 'xl'];

/// Categorias de viatura em que faz sentido perguntar pelo ar condicionado.
const acCategories = ['economy', 'comfort', 'xl', 'pickup', 'truck'];
const cargoCategories = ['delivery', 'cargo_tricycle', 'pickup', 'truck'];

/// Cores de viatura que o motorista pode escolher. O passageiro vê o ícone da
/// viatura nesta cor, para a reconhecer na rua.
const vehicleColors = <String, Color>{
  'Branco': Color(0xFFFFFFFF),
  'Prata': Color(0xFFC0C5CC),
  'Cinzento': Color(0xFF6B7280),
  'Preto': Color(0xFF111827),
  'Vermelho': Color(0xFFDC2626),
  'Azul': Color(0xFF2563EB),
  'Verde': Color(0xFF16A34A),
  'Amarelo': Color(0xFFFACC15),
  'Laranja': Color(0xFFF97316),
  'Castanho': Color(0xFF7C4A21),
  'Bege': Color(0xFFD9C3A0),
  'Dourado': Color(0xFFC9A227),
};

/// A cor a desenhar para o nome de cor de uma viatura (cinzento se desconhecida,
/// por exemplo em viaturas registadas antes de a cor ser escolhida numa lista).
Color vehicleColor(String name) {
  final key = name.trim().toLowerCase();
  for (final entry in vehicleColors.entries) {
    if (entry.key.toLowerCase() == key) return entry.value;
  }
  const synonyms = {
    'branca': 'Branco',
    'preta': 'Preto',
    'cinza': 'Cinzento',
    'vermelha': 'Vermelho',
    'amarela': 'Amarelo',
  };
  return vehicleColors[synonyms[key]] ?? const Color(0xFF9CA3AF);
}

/// Descodifica uma polyline codificada (precisão 5), como as do OSRM.
List<LatLng> decodePolyline(String? encoded) {
  if (encoded == null || encoded.isEmpty) return const [];
  final points = <LatLng>[];
  var index = 0, lat = 0, lng = 0;
  int next() {
    var result = 0, shift = 0, byte = 0;
    do {
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20 && index < encoded.length);
    // Sem o operador ~: na web ele devolve um inteiro sem sinal de 32 bits,
    // o que transformava coordenadas negativas em valores enormes.
    return (result & 1) != 0 ? -(result >> 1) - 1 : result >> 1;
  }

  while (index < encoded.length) {
    lat += next();
    if (index >= encoded.length) break;
    lng += next();
    points.add(LatLng(lat / 1e5, lng / 1e5));
  }
  return points;
}

/// Mostra um erro que fica no ecrã até o utilizador o fechar: um erro pede
/// atenção e não deve desaparecer sozinho antes de ser lido.
/// Texto a mostrar por um erro. As mensagens do servidor e as que o próprio app
/// escreve (texto simples) passam tal como estão; um erro técnico inesperado é
/// trocado por uma frase que o utilizador perceba.
String errorText(Object error) {
  if (error is String) return error;
  if (error is ApiException) return error.message;
  debugPrint('Erro inesperado: $error');
  return 'Ocorreu um erro inesperado. Tente novamente.';
}

void showError(BuildContext context, Object error) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: const Duration(days: 1),
        showCloseIcon: true,
        closeIconColor: Colors.white,
        backgroundColor: const Color(0xFFB91C1C),
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                errorText(error),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
}

/// Retira o erro do ecrã (ex.: quando o utilizador volta a tentar).
void clearError(BuildContext context) {
  if (context.mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
}
