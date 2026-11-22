import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/config.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/theme.dart';

/// Painel branco arredondado que assenta no fundo do ecrã, sobre o mapa.
class BottomPanel extends StatelessWidget {
  const BottomPanel({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        width: double.infinity,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.62,
        ),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 18)],
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

class PanelTitle extends StatelessWidget {
  const PanelTitle(this.title, {super.key, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              subtitle!,
              style: const TextStyle(color: BazaColors.muted, fontSize: 14),
            ),
          ),
      ],
    ),
  );
}

/// Recolha → destino, em duas linhas.
class RouteSummary extends StatelessWidget {
  const RouteSummary({
    super.key,
    required this.pickup,
    required this.dropoff,
    this.stops = const [],
  });
  final String pickup, dropoff;

  /// Paragens intermédias, mostradas entre a recolha e o destino.
  final List<String> stops;

  @override
  Widget build(BuildContext context) {
    Widget row(IconData icon, Color color, String text) => Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15),
          ),
        ),
      ],
    );
    return Column(
      children: [
        row(Icons.trip_origin, BazaColors.green, pickup),
        const SizedBox(height: 8),
        for (final stop in stops) ...[
          row(Icons.stop_circle_outlined, const Color(0xFFB45309), stop),
          const SizedBox(height: 8),
        ],
        row(Icons.flag, BazaColors.red, dropoff),
      ],
    );
  }
}

/// Cartão com o motorista (e viatura) ou com o passageiro.
class PartyCard extends StatelessWidget {
  const PartyCard({super.key, required this.party, this.showVehicle = true});
  final RideParty party;
  final bool showVehicle;

  @override
  Widget build(BuildContext context) {
    final v = showVehicle ? party.vehicle : null;
    final name = party.name.isEmpty ? 'Utilizador Bazá' : party.name;
    final plate = v == null
        ? null
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: BazaColors.ink, width: 1.5),
            ),
            child: Text(
              v.plate,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
          );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BazaColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Avatar(name: name, photoUrl: party.photoUrl, radius: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        if (party.rating != null) ...[
                          const SizedBox(width: 8),
                          const Icon(
                            Icons.star_rounded,
                            size: 18,
                            color: BazaColors.yellow,
                          ),
                          Text(
                            party.rating!
                                .toStringAsFixed(1)
                                .replaceAll('.', ','),
                          ),
                        ],
                      ],
                    ),
                    if (party.phone != null)
                      SelectableText(
                        party.phone!,
                        style: const TextStyle(color: BazaColors.muted),
                      ),
                  ],
                ),
              ),
            ],
          ),
          // A matrícula fica numa linha própria para caber em ecrãs estreitos.
          if (v != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                VehicleBadge(vehicle: v, size: 40),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    v.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15),
                  ),
                ),
                if (v.hasAC) ...[
                  const SizedBox(width: 8),
                  const Tooltip(
                    message: 'Com ar condicionado',
                    child: Icon(
                      Icons.ac_unit,
                      size: 18,
                      color: Color(0xFF0284C7),
                      semanticLabel: 'Com ar condicionado',
                    ),
                  ),
                ],
                const SizedBox(width: 10),
                plate!,
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class StarPicker extends StatelessWidget {
  const StarPicker({super.key, required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      for (var i = 1; i <= 5; i++)
        IconButton(
          tooltip: '$i de 5',
          iconSize: 40,
          onPressed: () => onChanged(i),
          icon: Icon(
            i <= value ? Icons.star_rounded : Icons.star_outline_rounded,
            color: i <= value ? BazaColors.yellow : const Color(0xFFD1D5DB),
          ),
        ),
    ],
  );
}

/// Linha "valor a pagar" usada no fim da corrida.
class FareLine extends StatelessWidget {
  const FareLine({super.key, required this.ride});
  final Ride ride;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(paymentIcons[ride.paymentMethod], color: BazaColors.muted),
      const SizedBox(width: 10),
      Expanded(
        child: Text(paymentLabels[ride.paymentMethod] ?? ride.paymentMethod),
      ),
      Text(
        kz(ride.fare),
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
      ),
    ],
  );
}

/// Botão que mostra um indicador enquanto a acção assíncrona decorre.
class AsyncButton extends StatefulWidget {
  const AsyncButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.outlined = false,
    this.danger = false,
  });
  final String label;
  final Future<void> Function()? onPressed;
  final bool outlined;
  final bool danger;

  @override
  State<AsyncButton> createState() => AsyncButtonState();
}

class AsyncButtonState extends State<AsyncButton> {
  bool _busy = false;

  /// Faz o mesmo que tocar no botão. Serve para a tecla Enter do teclado
  /// submeter o formulário: dá-se uma GlobalKey ao botão e chama-se
  /// `key.currentState?.trigger()` no `onSubmitted` do campo.
  void trigger() {
    if (widget.onPressed != null && !_busy) _run();
  }

  Future<void> _run() async {
    clearError(context); // nova tentativa: o erro anterior já não se aplica
    setState(() => _busy = true);
    try {
      await widget.onPressed!();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = _busy
        ? const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: BazaColors.ink,
            ),
          )
        : Text(widget.label);
    final onPressed = widget.onPressed == null || _busy ? null : _run;
    if (widget.outlined) {
      return OutlinedButton(
        onPressed: onPressed,
        style: widget.danger
            ? OutlinedButton.styleFrom(foregroundColor: BazaColors.red)
            : null,
        child: child,
      );
    }
    return FilledButton(onPressed: onPressed, child: child);
  }
}

/// Foto de perfil; sem foto (ou se falhar a carregar) mostra a inicial do nome.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.name,
    this.photoUrl,
    this.radius = 24,
  });
  final String name;

  /// Caminho devolvido pela API (ex.: "/uploads/abc.jpg").
  final String? photoUrl;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final url = fileUrl(photoUrl);
    return CircleAvatar(
      radius: radius,
      backgroundColor: BazaColors.yellow,
      foregroundColor: BazaColors.ink,
      foregroundImage: url == null ? null : NetworkImage(url),
      onForegroundImageError: url == null ? null : (_, _) {},
      child: Text(
        name.isEmpty ? '?' : name[0].toUpperCase(),
        style: TextStyle(fontWeight: FontWeight.w800, fontSize: radius * 0.75),
      ),
    );
  }
}

/// Logótipo do Bazá: o símbolo (seta de navegação) e, opcionalmente, o nome.
class BazaLogo extends StatelessWidget {
  const BazaLogo({
    super.key,
    this.size = 32,
    this.wordmark = true,
    this.color = BazaColors.ink,
  });

  /// Altura do símbolo; o nome acompanha a escala.
  final double size;
  final bool wordmark;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Bazá',
      image: true,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(
              'assets/brand/mark.svg',
              width: size,
              height: size,
            ),
            if (wordmark) ...[
              SizedBox(width: size * 0.28),
              Text(
                'Bazá',
                style: TextStyle(
                  fontSize: size * 0.78,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -size * 0.02,
                  color: color,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Em serviços de carga: o tipo de viatura, o que se transporta e os ajudantes.
class CargoLine extends StatelessWidget {
  const CargoLine({super.key, required this.ride});
  final Ride ride;

  @override
  Widget build(BuildContext context) {
    final helpers = ride.helpers == 0
        ? ''
        : ride.helpers == 1
        ? ' · 1 ajudante'
        : ' · ${ride.helpers} ajudantes';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            categoryIcons[ride.category] ?? Icons.inventory_2_outlined,
            size: 18,
            color: BazaColors.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${categoryLabels[ride.category] ?? 'Carga'}: ${ride.cargoNote ?? ''}$helpers',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}

/// Selo da viatura: o ícone do tipo de viatura pintado com a cor dela, para o
/// passageiro saber o que procurar na rua.
class VehicleBadge extends StatelessWidget {
  const VehicleBadge({super.key, required this.vehicle, this.size = 44});
  final Vehicle vehicle;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = vehicleColor(vehicle.color);
    // Cores claras (branco, prata, amarelo) precisam de fundo escuro para se verem.
    final light = color.computeLuminance() > 0.55;
    return Semantics(
      label: 'Viatura de cor ${vehicle.color}',
      image: true,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: light ? BazaColors.ink : Colors.white,
          shape: BoxShape.circle,
          border: Border.all(
            color: light ? BazaColors.ink : const Color(0xFFD1D5DB),
            width: 1.5,
          ),
        ),
        child: Icon(
          categoryIcons[vehicle.category] ?? Icons.directions_car,
          color: color,
          size: size * 0.6,
        ),
      ),
    );
  }
}

/// Preço ajustável com − e +, usado na negociação entre passageiro e motorista.
class PriceStepper extends StatelessWidget {
  const PriceStepper({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.reference,
    this.referenceLabel = 'Preço sugerido',
  });

  final int value, min, max;
  final ValueChanged<int> onChanged;

  /// Preço de comparação (a tarifa, ou o preço do passageiro), mostrado por baixo.
  final int? reference;
  final String referenceLabel;

  /// Passos maiores em preços maiores, para não exigir dezenas de toques.
  int get _step => value >= 10000 ? 500 : (value >= 2000 ? 100 : 50);

  @override
  Widget build(BuildContext context) {
    final ref = reference;
    final diff = ref == null ? 0 : value - ref;
    Widget button(IconData icon, String tooltip, int next) =>
        IconButton.filledTonal(
          tooltip: tooltip,
          iconSize: 26,
          style: IconButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: BazaColors.ink,
          ),
          onPressed: next == value ? null : () => onChanged(next),
          icon: Icon(icon),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: BazaColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          button(
            Icons.remove,
            'Baixar o preço',
            (value - _step).clamp(min, max),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  kz(value),
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (ref != null)
                  Text(
                    diff == 0
                        ? referenceLabel
                        : '$referenceLabel: ${kz(ref)} (${diff > 0 ? '+' : '−'}${kz(diff.abs())})',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: diff == 0
                          ? BazaColors.muted
                          : (diff > 0
                                ? BazaColors.green
                                : const Color(0xFFB45309)),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
          button(Icons.add, 'Subir o preço', (value + _step).clamp(min, max)),
        ],
      ),
    );
  }
}

/// Ligações para os Termos de Utilização e a Política de Privacidade.
class LegalLinks extends StatelessWidget {
  const LegalLinks({super.key, this.prefix});

  /// Frase antes das ligações, ex.: "Ao continuar, aceita os".
  final String? prefix;

  static Future<void> _open(BuildContext context, String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);
    if (!ok && context.mounted)
      showError(context, 'Não foi possível abrir a página.');
  }

  @override
  Widget build(BuildContext context) {
    Widget link(String label, String url) => InkWell(
      onTap: () => _open(context, url),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          label,
          style: const TextStyle(
            color: BazaColors.ink,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      children: [
        if (prefix != null)
          Text(prefix!, style: const TextStyle(color: BazaColors.muted)),
        link('Termos de Utilização', termsUrl),
        const Text('e', style: TextStyle(color: BazaColors.muted)),
        link('Política de Privacidade', privacyUrl),
      ],
    );
  }
}

/// Campo para escrever um preço livre (serviços de preço combinado), com o
/// botão que o envia. Aceita múltiplos de 50 Kz.
class PriceInput extends StatefulWidget {
  const PriceInput({
    super.key,
    required this.label,
    required this.action,
    required this.onSubmit,
    this.initial,
  });
  final String label;

  /// Texto do botão, a partir do valor escrito: "Propor 45 000 Kz".
  final String Function(int amount) action;
  final Future<void> Function(int amount) onSubmit;
  final int? initial;

  @override
  State<PriceInput> createState() => _PriceInputState();
}

class _PriceInputState extends State<PriceInput> {
  late final _controller = TextEditingController(
    text: widget.initial == null ? '' : '${widget.initial}',
  );
  final _buttonKey = GlobalKey<AsyncButtonState>();

  int? get _amount => int.tryParse(_controller.text);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final amount = _amount;
    if (amount == null || amount <= 0) throw 'Escreva o preço em kwanzas.';
    if (amount % 50 != 0) throw 'O preço tem de ser múltiplo de 50 Kz.';
    await widget.onSubmit(amount);
    if (mounted) FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final amount = _amount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(7),
          ],
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _buttonKey.currentState?.trigger(),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          decoration: InputDecoration(
            labelText: widget.label,
            suffixText: 'Kz',
          ),
        ),
        if (amount != null && amount > 0 && amount != widget.initial) ...[
          const SizedBox(height: 8),
          AsyncButton(
            key: _buttonKey,
            label: widget.action(amount),
            outlined: true,
            onPressed: _submit,
          ),
        ],
      ],
    );
  }
}

/// Campo de senha com o botão de mostrar/esconder.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    this.label = 'Senha',
    this.helper,
    this.isNew = false,
    this.autofocus = false,
    this.action = TextInputAction.done,
    this.onSubmitted,
  });
  final TextEditingController controller;
  final String label;
  final String? helper;

  /// Senha a criar (ajuda o gestor de senhas do telemóvel a guardá-la).
  final bool isNew;
  final bool autofocus;
  final TextInputAction action;
  final VoidCallback? onSubmitted;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) => TextField(
    controller: widget.controller,
    obscureText: _hidden,
    autofocus: widget.autofocus,
    textInputAction: widget.action,
    onSubmitted: (_) => widget.onSubmitted?.call(),
    autofillHints: [
      widget.isNew ? AutofillHints.newPassword : AutofillHints.password,
    ],
    decoration: InputDecoration(
      labelText: widget.label,
      helperText: widget.helper,
      suffixIcon: IconButton(
        tooltip: _hidden ? 'Mostrar a senha' : 'Esconder a senha',
        icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
        onPressed: () => setState(() => _hidden = !_hidden),
      ),
    ),
  );
}

/// Regras da senha do app, com a mensagem a mostrar se falhar.
void checkNewPassword(String password, String confirmation) {
  if (password.length < 6) throw 'A senha deve ter pelo menos 6 caracteres.';
  if (password != confirmation) throw 'As duas senhas não são iguais.';
}

/// Separa o número de telefone de 3 em 3 enquanto se escreve ("923 456 789"),
/// como no exemplo do campo. Números com indicativo ("+244…") também se
/// agrupam, depois do indicativo.
class PhoneInputFormatter extends TextInputFormatter {
  const PhoneInputFormatter();

  static String format(String raw) {
    final plus = raw.trimLeft().startsWith('+');
    var digits = raw.replaceAll(RegExp(r'\D'), '');
    final max = plus ? 15 : 9;
    if (digits.length > max) digits = digits.substring(0, max);
    final out = StringBuffer(plus ? '+' : '');
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && i % 3 == 0) out.write(' ');
      out.write(digits[i]);
    }
    return out.toString();
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = format(newValue.text);
    // Mantém o cursor depois do mesmo número de dígitos que tinha antes dele.
    final end = newValue.selection.end.clamp(0, newValue.text.length);
    final before = newValue.text
        .substring(0, end)
        .replaceAll(RegExp(r'\D'), '')
        .length;
    var offset = 0, seen = 0;
    while (offset < text.length && seen < before) {
      if (RegExp(r'\d').hasMatch(text[offset])) seen++;
      offset++;
    }
    if (before == 0 && text.startsWith('+') && end > 0) offset = 1;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}
