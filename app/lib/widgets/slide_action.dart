import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../core/theme.dart';

/// Botão de deslizar para confirmar, para acções do motorista que não devem
/// acontecer por um toque acidental (ficar online, iniciar ou terminar viagem).
///
/// O polegar arrasta-se até ao fim da pista; ao largar depois de ~85% do
/// percurso, [onSubmit] é chamado. Com [reversed], o polegar começa à direita e
/// desliza-se para a esquerda (usado para "ficar offline").
class SlideAction extends StatefulWidget {
  const SlideAction({
    super.key,
    required this.label,
    required this.onSubmit,
    this.color = BazaColors.yellow,
    this.foreground = BazaColors.ink,
    this.icon,
    this.reversed = false,
  });

  final String label;
  final Future<void> Function() onSubmit;

  /// Cor da pista; [foreground] é a cor do texto sobre ela.
  final Color color;
  final Color foreground;

  /// Ícone no polegar (por omissão, setas na direcção do gesto).
  final IconData? icon;
  final bool reversed;

  @override
  State<SlideAction> createState() => _SlideActionState();
}

class _SlideActionState extends State<SlideAction>
    with SingleTickerProviderStateMixin {
  static const _height = 62.0;
  static const _thumb = 52.0;
  static const _pad = 5.0;
  static const _threshold = 0.85;

  /// Dá vida às setas: indicam para onde deslizar.
  late final _hint = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  double _progress = 0; // 0 = repouso, 1 = fim da pista
  bool _dragging = false;
  bool _busy = false;

  @override
  void dispose() {
    _hint.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    HapticFeedback.mediumImpact();
    clearError(context);
    setState(() {
      _busy = true;
      _progress = 1;
    });
    try {
      await widget.onSubmit();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      // Volta ao início: se a acção resultou, o ecrã mostra o passo seguinte.
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = 0;
        });
      }
    }
  }

  void _onDrag(DragUpdateDetails d, double travel) {
    if (_busy || travel <= 0) return;
    final delta = (widget.reversed ? -d.delta.dx : d.delta.dx) / travel;
    setState(() => _progress = (_progress + delta).clamp(0.0, 1.0));
  }

  void _onDragEnd() {
    if (_busy) return;
    _dragging = false;
    if (_progress >= _threshold) {
      _submit();
    } else {
      setState(() => _progress = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final arrow = widget.reversed
        ? Icons.keyboard_double_arrow_left
        : Icons.keyboard_double_arrow_right;
    return Semantics(
      button: true,
      label: widget.label,
      hint: widget.reversed
          ? 'Deslize para a esquerda para confirmar'
          : 'Deslize para a direita para confirmar',
      // Quem usa leitor de ecrã (ou teclado) confirma com a acção de activar.
      onTap: _busy ? null : _submit,
      child: LayoutBuilder(
        builder: (context, box) {
          final travel = box.maxWidth - _thumb - _pad * 2;
          final offset = _pad + travel * _progress;
          final duration = _dragging
              ? Duration.zero
              : const Duration(milliseconds: 220);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => _dragging = true,
            onHorizontalDragUpdate: (d) => _onDrag(d, travel),
            onHorizontalDragEnd: (_) => _onDragEnd(),
            onHorizontalDragCancel: _onDragEnd,
            child: Container(
              height: _height,
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(_height / 2),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Rasto por onde o polegar já passou.
                  AnimatedPositioned(
                    duration: duration,
                    curve: Curves.easeOut,
                    top: 0,
                    bottom: 0,
                    left: widget.reversed ? null : 0,
                    right: widget.reversed ? 0 : null,
                    width: offset + _thumb / 2,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.14),
                    ),
                  ),
                  // Texto e setas, que se desvanecem à medida que se desliza.
                  Opacity(
                    opacity: (1 - _progress * 1.6).clamp(0.0, 1.0),
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: widget.reversed ? 16 : _thumb + 12,
                        right: widget.reversed ? _thumb + 12 : 16,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        textDirection: widget.reversed
                            ? TextDirection.rtl
                            : TextDirection.ltr,
                        children: [
                          Flexible(
                            child: Text(
                              widget.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textDirection: TextDirection.ltr,
                              style: TextStyle(
                                color: widget.foreground,
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          ExcludeSemantics(
                            child: _HintArrows(
                              animation: _hint,
                              icon: arrow,
                              color: widget.foreground,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  AnimatedPositioned(
                    duration: duration,
                    curve: Curves.easeOut,
                    left: widget.reversed ? null : offset,
                    right: widget.reversed ? offset : null,
                    child: Container(
                      width: _thumb,
                      height: _thumb,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black38,
                            blurRadius: 6,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: _busy
                          ? const Padding(
                              padding: EdgeInsets.all(15),
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: BazaColors.ink,
                              ),
                            )
                          : Icon(
                              widget.icon ?? arrow,
                              color: BazaColors.ink,
                              size: 26,
                            ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Três setas que acendem em sequência, na direcção do gesto.
class _HintArrows extends StatelessWidget {
  const _HintArrows({
    required this.animation,
    required this.icon,
    required this.color,
  });
  final Animation<double> animation;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // Respeita a preferência do sistema por menos movimento.
    if (MediaQuery.disableAnimationsOf(context)) {
      return Icon(icon, size: 20, color: color.withValues(alpha: 0.7));
    }
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        // Um brilho que percorre o ícone de 0.35 a 1 de opacidade.
        final t = (animation.value * 2 - 1).abs(); // 1 → 0 → 1
        return Icon(
          icon,
          size: 20,
          color: color.withValues(alpha: 0.35 + 0.65 * (1 - t)),
        );
      },
    );
  }
}
