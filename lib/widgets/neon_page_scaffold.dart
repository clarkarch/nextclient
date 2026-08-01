import 'package:flutter/material.dart';

import '../theme/neon.dart';

/// Shared scrollable page scaffold: layered background + optional top bar
/// (back button + title) + padded scrollable content.
class NeonPageScaffold extends StatefulWidget {
  final String? title;
  final bool showBack;
  final List<Widget>? actions;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final ScrollController? scrollController;
  final Color? background;

  const NeonPageScaffold({
    super.key,
    this.title,
    this.showBack = false,
    this.actions,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(28, 20, 28, 32),
    this.scrollController,
    this.background,
  });

  @override
  State<NeonPageScaffold> createState() => _NeonPageScaffoldState();
}

class _NeonPageScaffoldState extends State<NeonPageScaffold> {
  ScrollController? _ownedController;

  ScrollController get _controller {
    final external = widget.scrollController;
    if (external != null) return external;
    return _ownedController ??= ScrollController();
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.background ?? Neon.bgA,
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topLeft,
            radius: 1.4,
            colors: [Color(0x0F00D9FF), Color(0x00000000)],
            stops: [0, 0.5],
          ),
        ),
        child: Column(
          children: [
            if (widget.title != null ||
                widget.showBack ||
                (widget.actions != null && widget.actions!.isNotEmpty))
              _TopBar(
                title: widget.title,
                showBack: widget.showBack,
                actions: widget.actions ?? const [],
              ),
            Expanded(
              child: Scrollbar(
                controller: _controller,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _controller,
                  padding: widget.padding,
                  child: widget.child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final String? title;
  final bool showBack;
  final List<Widget> actions;

  const _TopBar({
    required this.title,
    required this.showBack,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x1FFFFFFF))),
      ),
      child: Row(
        children: [
          if (showBack) ...[
            _RoundIconButton(
              icon: Icons.arrow_back,
              onTap: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 12),
          ],
          if (title != null)
            Text(
              title!,
              style: const TextStyle(
                color: Neon.ink,
                fontSize: 17,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
              ),
            ),
          const Spacer(),
          ...actions,
        ],
      ),
    );
  }
}

/// Circular ghost icon button used across bars.
class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _RoundIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: const Color(0x0FFFFFFF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x22FFFFFF)),
        ),
        child: Icon(icon, size: 20, color: Neon.inkSoft),
      ),
    );
  }
}
