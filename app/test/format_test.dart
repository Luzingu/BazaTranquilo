import 'package:baza/core/api.dart';
import 'package:baza/core/format.dart';
import 'package:baza/widgets/common.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodePolyline lida com coordenadas negativas (Angola fica a sul do equador)', () {
    // Exemplo de referência do formato: (38.5,-120.2) (40.7,-120.95) (43.252,-126.453)
    final points = decodePolyline(r'_p~iF~ps|U_ulLnnqC_mqNvxq`@');
    expect(points.length, 3);
    expect(points[0].latitude, closeTo(38.5, 1e-6));
    expect(points[0].longitude, closeTo(-120.2, 1e-6));
    expect(points[2].latitude, closeTo(43.252, 1e-6));
    expect(points[2].longitude, closeTo(-126.453, 1e-6));
  });

  test('kz formata milhares', () {
    expect(kz(4850), '4 850 Kz');
    expect(kz(-727), '−727 Kz');
  });

  test('erros técnicos não chegam ao utilizador em bruto', () {
    expect(errorText('Escreva o seu nome.'), 'Escreva o seu nome.');
    expect(
      errorText(ApiException(409, 'Já tem uma corrida em curso.')),
      'Já tem uma corrida em curso.',
    );
    expect(
      errorText(
        UnsupportedError(
          'getLastKnownPosition is not supported on the web platform.',
        ),
      ),
      'Ocorreu um erro inesperado. Tente novamente.',
    );
  });

  test('telefone separado de 3 em 3 ao escrever', () {
    expect(PhoneInputFormatter.format('923456789'), '923 456 789');
    expect(PhoneInputFormatter.format('9234'), '923 4');
    expect(PhoneInputFormatter.format('923 45 6789 00'), '923 456 789');
    expect(PhoneInputFormatter.format('+244923456789'), '+244 923 456 789');
    const f = PhoneInputFormatter();
    final v = f.formatEditUpdate(
      TextEditingValue.empty,
      const TextEditingValue(
        text: '9234',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    expect(v.text, '923 4');
    expect(v.selection.end, 5);
  });
}
