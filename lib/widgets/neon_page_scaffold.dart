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
  final Widget? header;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry sliverPadding;
  final ScrollController? scrollController;
  final Color? background;

  /// Overrides the background style. Defaults to the user's selected style via
  /// [BackgroundGlow]; pages that build from [UserSettings] pass the selected
  /// style explicitly if they need to override it.
  final BackgroundStyle? style;

  /// Optional pull-to-refresh handler — wraps the scroll view with a
  /// [RefreshIndicator] using neon accent colors.
  final Future<void> Function()? onRefresh;

  const NeonPageScaffold({
    super.key,
    this.title,
    this.showBack = false,
    this.actions,
    this.child,
    this.slivers,
    this.header,
    this.padding = const EdgeInsets.fromLTRB(28, 20, 28, 32),
    this.sliverPadding = const EdgeInsets.symmetric(horizontal: 28),
    this.scrollController,
    this.background,
    this.style,
    this.onRefresh,
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
    try {
      _ownedController?.removeListener(_onScroll);
    } catch (_) {}
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final explicit = widget.style;
    Widget body;
    if (explicit != null) {
      body = _decorated(explicit);
    } else {
      body = ValueListenableBuilder<BackgroundStyle>(
        valueListenable: BackgroundGlow.current,
        builder: (context, style, _) => _decorated(style),
      );
    }
    return Scaffold(
      backgroundColor: widget.background ?? Neon.bgA,
      body: body,
    );
  }

  // Tracks scroll offset to fade the top hairline glow.
  double _scrollOffset = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller.addListener(_onScroll);
    });
  }

  void _onScroll() {
    if (!mounted) return;
    final offset = _controller.hasClients ? _controller.offset : 0.0;
    if ((offset - _scrollOffset).abs() > 1) {
      setState(() => _scrollOffset = offset);
    }
  }

  @override
  void didUpdateWidget(covariant NeonPageScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController?.removeListener(_onScroll);
      _controller.addListener(_onScroll);
    }
  }

  Widget _decorated(BackgroundStyle style) {
    final showTopGlow = _scrollOffset > 4;
    return Stack(
      fit: StackFit.expand,
      children: [
        NeonBackground(style: style),
        // Content stays inside the status-bar / notch inset (the background
        // behind it is still edge-to-edge). The bottom is left to each page's
        // own bottom-ish UI (bottom nav handles its inset itself).
        SafeArea(
          top: true,
          bottom: false,
          child: Column(
            children: [
              if (widget.header != null)
                widget.header!
              else if (widget.title != null ||
                  widget.showBack ||
                  (widget.actions != null && widget.actions!.isNotEmpty))
                _TopBar(
                  title: widget.title,
                  showBack: widget.showBack,
                  actions: widget.actions ?? const [],
                  scrolled: showTopGlow,
                ),
              // Animated top hairline — glows when scrolled
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 1,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: showTopGlow
                        ? [
                            Neon.accent.withValues(alpha: 0.0),
                            Neon.accent.withValues(alpha: 0.28),
                            Neon.accent.withValues(alpha: 0.0),
                          ]
                        : [
                            Colors.transparent,
                            Colors.transparent,
                          ],
                  ),
                ),
              ),
              Expanded(
                child: Stack(
                  children: [
                    Scrollbar(
                      controller: _controller,
                      thumbVisibility: false,
                      thickness: 4,
                      radius: const Radius.circular(8),
                      interactive: true,
                      child: widget.onRefresh == null
                          ? _scrollView()
                          : RefreshIndicator(
                              onRefresh: widget.onRefresh!,
                              color: Neon.accent,
                              backgroundColor: Neon.bgC,
                              child: _scrollView(),
                            ),
                    ),
                    // Bottom fade — hints there's more to scroll
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 40,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [
                                Neon.bgA.withValues(alpha: 0.55),
                                const Color(0x0008080D),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _scrollView() {
    if (widget.slivers != null) {
      return CustomScrollView(
        controller: _controller,
        physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          for (final sliver in widget.slivers!)
            SliverPadding(padding: widget.sliverPadding, sliver: sliver),
        ],
      );
    }
    return SingleChildScrollView(
      controller: _controller,
      physics:
          const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: widget.padding,
      child: widget.child,
    );
  }
}

class _TopBar extends StatelessWidget {
  final String? title;
  final bool showBack;
  final List<Widget> actions;
  final bool scrolled;

  const _TopBar({
    required this.title,
    required this.showBack,
    required this.actions,
    this.scrolled = false,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: scrolled
            ? Neon.bgB.withValues(alpha: 0.72)
            : Colors.transparent,
        border: scrolled
            ? const Border(
                bottom: BorderSide(color: Color(0x1A252C3F), width: 1))
            : null,
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
                shadows: [Shadow(color: Colors.black, blurRadius: 8)],
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
class _RoundIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;

  static final _labels = {
    Icons.arrow_back: 'Back',
    Icons.close: 'Close',
  };

  const _RoundIconButton({required this.icon, required this.onTap});

  @override
  State<_RoundIconButton> createState() => _RoundIconButtonState();
}

class _RoundIconButtonState extends State<_RoundIconButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Tooltip(
          message: _RoundIconButton._labels[widget.icon] ?? 'Action',
          child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: _hover
                ? Neon.accent.withValues(alpha: 0.10)
                : const Color(0x0FFFFFFF),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hover
                  ? Neon.accent.withValues(alpha: 0.38)
                  : Neon.outline.withValues(alpha: 0.55),
            ),
            boxShadow: _hover
                ? [
                    BoxShadow(
                        color: Neon.accent.withValues(alpha: 0.18),
                        blurRadius: 12)
                  ]
                : null,
          ),
          child: Icon(widget.icon,
              size: 20,
              color: _hover ? Neon.accent : Neon.inkSoft),
          ),
        ),
      ),
    );
  }
}
