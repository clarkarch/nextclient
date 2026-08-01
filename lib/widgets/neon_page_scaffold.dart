import 'package:flutter/material.dart';

import '../theme/neon.dart';

/// Shared page scaffold: layered background + optional top bar
/// (back button + title) + padded scrollable content.
///
/// Pass [slivers] for lazy content (grids/carousel); otherwise pass [child]
/// for a simple padded scroll body.
class NeonPageScaffold extends StatefulWidget {
  final String? title;
  final bool showBack;
  final List<Widget>? actions;
  final Widget? child;
  final List<Widget>? slivers;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry sliverPadding;
  final ScrollController? scrollController;
  final Color? background;

  const NeonPageScaffold({
    super.key,
    this.title,
    this.showBack = false,
    this.actions,
    this.child,
    this.slivers,
    this.padding = const EdgeInsets.fromLTRB(28, 20, 28, 32),
    this.sliverPadding = const EdgeInsets.symmetric(horizontal: 28),
    this.scrollController,
    this.background,
  }) : assert(child == null || slivers == null,
            'Provide either child or slivers, not both.');

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
                child: _scrollView(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scrollView() {
    if (widget.slivers != null) {
      return CustomScrollView(
        controller: _controller,
        slivers: [
          for (final sliver in widget.slivers!)
            SliverPadding(padding: widget.sliverPadding, sliver: sliver),
        ],
      );
    }
    return SingleChildScrollView(
      controller: _controller,
      padding: widget.padding,
      child: widget.child,
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
        border: Border(bottom: BorderSide(color: Color(0x12FFFFFF))),
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
        ),
        child: Icon(icon, size: 20, color: Neon.inkSoft),
      ),
    );
  }
}
