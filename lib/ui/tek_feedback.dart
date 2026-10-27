import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/tek_tokens.dart';

/// Centralized feedback, toast, and smart animation utilities for TEKFIX ERP.
class TekFeedback {
  TekFeedback._();

  /// Displays a smooth floating success toast with a green checkmark
  static void showSuccess(
    BuildContext context,
    String message, {
    String? subtitle,
    Duration duration = const Duration(seconds: 3),
  }) {
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        elevation: 8,
        backgroundColor: TekColors.cardBg,
        duration: duration,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: TekColors.success.withValues(alpha: 0.5), width: 1.2),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        content: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: TekColors.success.withValues(alpha: 0.18),
                shape: BoxShape.circle,
                border: Border.all(color: TekColors.success.withValues(alpha: 0.4)),
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                color: TekColors.success,
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    style: const TextStyle(
                      color: TekColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      fontFamilyFallback: TekTypography.malayalamFallback,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: TekColors.textSecondary,
                        fontSize: 12,
                        fontFamilyFallback: TekTypography.malayalamFallback,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Displays a smooth floating error toast with a red warning icon and optional retry action
  static void showError(
    BuildContext context,
    String message, {
    String? details,
    VoidCallback? onRetry,
    Duration duration = const Duration(seconds: 4),
  }) {
    HapticFeedback.heavyImpact();
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        elevation: 8,
        backgroundColor: TekColors.cardBg,
        duration: duration,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: TekColors.error.withValues(alpha: 0.6), width: 1.2),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        content: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: TekColors.error.withValues(alpha: 0.18),
                shape: BoxShape.circle,
                border: Border.all(color: TekColors.error.withValues(alpha: 0.5)),
              ),
              child: const Icon(
                Icons.error_outline_rounded,
                color: TekColors.error,
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    style: const TextStyle(
                      color: TekColors.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      fontFamilyFallback: TekTypography.malayalamFallback,
                    ),
                  ),
                  if (details != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      details,
                      style: const TextStyle(
                        color: TekColors.textSecondary,
                        fontSize: 11.5,
                        fontFamilyFallback: TekTypography.malayalamFallback,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (onRetry != null)
              TextButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  onRetry();
                },
                child: const Text(
                  'വീണ്ടും ശ്രമിക്കുക (Retry)',
                  style: TextStyle(
                    color: TekColors.electricCyan,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Displays an informational or progress banner
  static void showInfo(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 3),
  }) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        elevation: 6,
        backgroundColor: TekColors.cardBg,
        duration: duration,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: TekColors.border, width: 1.2),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        content: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: TekColors.primaryBlue.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.info_outline_rounded,
                color: TekColors.electricCyan,
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: TekColors.textPrimary,
                  fontSize: 13.5,
                  fontFamilyFallback: TekTypography.malayalamFallback,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Smart Red Signal Badge with optional pulsing animation for urgent alerts
class TekRedSignalBadge extends StatefulWidget {
  final int count;
  final bool pulse;
  final double size;
  final Color badgeColor;
  final Widget? child;
  final VoidCallback? onTap;

  const TekRedSignalBadge({
    super.key,
    required this.count,
    bool pulse = true,
    bool? showPulse,
    this.size = 18,
    this.badgeColor = TekColors.error,
    this.child,
    this.onTap,
  }) : pulse = showPulse ?? pulse;

  @override
  State<TekRedSignalBadge> createState() => _TekRedSignalBadgeState();
}

class _TekRedSignalBadgeState extends State<TekRedSignalBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.pulse) {
      _pulseCtrl.repeat(reverse: true);
    }
    _scaleAnim = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(TekRedSignalBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulse && !_pulseCtrl.isAnimating) {
      _pulseCtrl.repeat(reverse: true);
    } else if (!widget.pulse && _pulseCtrl.isAnimating) {
      _pulseCtrl.stop();
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.count <= 0 && widget.child == null) return const SizedBox.shrink();

    final text = widget.count > 99 ? '99+' : '${widget.count}';

    Widget badgeWidget = widget.count <= 0
        ? const SizedBox.shrink()
        : ScaleTransition(
            scale: widget.pulse ? _scaleAnim : const AlwaysStoppedAnimation(1.0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              constraints: BoxConstraints(minWidth: widget.size, minHeight: widget.size),
              decoration: BoxDecoration(
                color: widget.badgeColor,
                borderRadius: BorderRadius.circular(widget.size / 2),
                boxShadow: [
                  BoxShadow(
                    color: widget.badgeColor.withValues(alpha: 0.6),
                    blurRadius: 6,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  text,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: widget.size * 0.58,
                    fontWeight: FontWeight.bold,
                    height: 1.0,
                  ),
                ),
              ),
            ),
          );

    if (widget.child == null) {
      return GestureDetector(
        onTap: widget.onTap,
        child: badgeWidget,
      );
    }

    return GestureDetector(
      onTap: widget.onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child!,
          if (widget.count > 0)
            Positioned(
              top: -4,
              right: -4,
              child: badgeWidget,
            ),
        ],
      ),
    );
  }
}

/// Enterprise Button with complete interactive lifecycle:
/// Tap -> Press Animation -> Duplicate Submission Lock -> Progress Spinner -> Result -> Restore.
class TekButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final Future<void> Function()? onPressed;
  final bool isPrimary;
  final bool isDanger;
  final Color? customColor;
  final double? width;
  final double height;
  final EdgeInsets padding;

  const TekButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.isPrimary = true,
    this.isDanger = false,
    this.customColor,
    this.width,
    this.height = 42,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  @override
  State<TekButton> createState() => _TekButtonState();
}

class _TekButtonState extends State<TekButton> {
  bool _isLoading = false;
  bool _isPressed = false;

  Future<void> _handlePress() async {
    if (_isLoading || widget.onPressed == null) return;

    setState(() => _isLoading = true);
    HapticFeedback.lightImpact();

    try {
      await widget.onPressed!();
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    Border? border;

    if (widget.isDanger) {
      bg = TekColors.error;
      fg = Colors.white;
    } else if (widget.customColor != null) {
      bg = widget.customColor!;
      fg = Colors.white;
    } else if (widget.isPrimary) {
      bg = TekColors.primaryBlue;
      fg = Colors.white;
    } else {
      bg = TekColors.cardBg;
      fg = TekColors.textPrimary;
      border = Border.all(color: TekColors.border, width: 1.2);
    }

    return AnimatedScale(
      scale: _isPressed ? 0.96 : 1.0,
      duration: const Duration(milliseconds: 100),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: Material(
          color: widget.onPressed == null ? bg.withValues(alpha: 0.5) : bg,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onHighlightChanged: (val) => setState(() => _isPressed = val),
            onTap: widget.onPressed == null || _isLoading ? null : _handlePress,
            child: Container(
              padding: widget.padding,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: border,
                gradient: widget.isPrimary && !widget.isDanger
                    ? TekColors.primaryGradient
                    : null,
                boxShadow: widget.isPrimary && widget.onPressed != null
                    ? TekColors.primaryGlow
                    : null,
              ),
              child: Center(
                child: _isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: Colors.white,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (widget.icon != null) ...[
                            Icon(widget.icon, size: 17, color: fg),
                            const SizedBox(width: 8),
                          ],
                          Text(
                            widget.label,
                            style: TextStyle(
                              color: fg,
                              fontWeight: FontWeight.w600,
                              fontSize: 13.5,
                              fontFamilyFallback: TekTypography.malayalamFallback,
                            ),
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
