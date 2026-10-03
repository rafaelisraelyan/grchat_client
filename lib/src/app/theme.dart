import 'package:flutter/material.dart';

/// Semantic color tokens. Every widget uses these — no scattered
/// hardcoded colors. Same token names drive dark and light themes.
@immutable
class GrchatColors extends ThemeExtension<GrchatColors> {
  const GrchatColors({
    required this.bgApp,
    required this.bgRail,
    required this.bgSidebar,
    required this.bgChat,
    required this.surface,
    required this.surfaceElevated,
    required this.surfaceHover,
    required this.surfaceSelected,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.borderSubtle,
    required this.accent,
    required this.accentHover,
    required this.accentMuted,
    required this.success,
    required this.warning,
    required this.danger,
    required this.online,
    required this.onAccent,
  });

  final Color bgApp;
  final Color bgRail;
  final Color bgSidebar;
  final Color bgChat;
  final Color surface;
  final Color surfaceElevated;
  final Color surfaceHover;
  final Color surfaceSelected;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color borderSubtle;
  final Color accent;
  final Color accentHover;
  final Color accentMuted;
  final Color success;
  final Color warning;
  final Color danger;
  final Color online;
  final Color onAccent;

  static GrchatColors of(BuildContext context) =>
      Theme.of(context).extension<GrchatColors>()!;

  @override
  GrchatColors copyWith({
    Color? bgApp,
    Color? bgRail,
    Color? bgSidebar,
    Color? bgChat,
    Color? surface,
    Color? surfaceElevated,
    Color? surfaceHover,
    Color? surfaceSelected,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? borderSubtle,
    Color? accent,
    Color? accentHover,
    Color? accentMuted,
    Color? success,
    Color? warning,
    Color? danger,
    Color? online,
    Color? onAccent,
  }) {
    return GrchatColors(
      bgApp: bgApp ?? this.bgApp,
      bgRail: bgRail ?? this.bgRail,
      bgSidebar: bgSidebar ?? this.bgSidebar,
      bgChat: bgChat ?? this.bgChat,
      surface: surface ?? this.surface,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      surfaceHover: surfaceHover ?? this.surfaceHover,
      surfaceSelected: surfaceSelected ?? this.surfaceSelected,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      borderSubtle: borderSubtle ?? this.borderSubtle,
      accent: accent ?? this.accent,
      accentHover: accentHover ?? this.accentHover,
      accentMuted: accentMuted ?? this.accentMuted,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      online: online ?? this.online,
      onAccent: onAccent ?? this.onAccent,
    );
  }

  @override
  GrchatColors lerp(ThemeExtension<GrchatColors>? other, double t) {
    if (other is! GrchatColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return GrchatColors(
      bgApp: l(bgApp, other.bgApp),
      bgRail: l(bgRail, other.bgRail),
      bgSidebar: l(bgSidebar, other.bgSidebar),
      bgChat: l(bgChat, other.bgChat),
      surface: l(surface, other.surface),
      surfaceElevated: l(surfaceElevated, other.surfaceElevated),
      surfaceHover: l(surfaceHover, other.surfaceHover),
      surfaceSelected: l(surfaceSelected, other.surfaceSelected),
      textPrimary: l(textPrimary, other.textPrimary),
      textSecondary: l(textSecondary, other.textSecondary),
      textMuted: l(textMuted, other.textMuted),
      borderSubtle: l(borderSubtle, other.borderSubtle),
      accent: l(accent, other.accent),
      accentHover: l(accentHover, other.accentHover),
      accentMuted: l(accentMuted, other.accentMuted),
      success: l(success, other.success),
      warning: l(warning, other.warning),
      danger: l(danger, other.danger),
      online: l(online, other.online),
      onAccent: l(onAccent, other.onAccent),
    );
  }
}

const _accent = Color(0xFF574CC9);

const grchatDarkColors = GrchatColors(
  bgApp: Color(0xFF19181B),
  bgRail: Color(0xFF141315),
  bgSidebar: Color(0xFF1E1D20),
  bgChat: Color(0xFF1B1A1D),
  surface: Color(0xFF26252B),
  surfaceElevated: Color(0xFF2E2D33),
  surfaceHover: Color(0xFF2A2930),
  surfaceSelected: Color(0xFF2B2940),
  textPrimary: Color(0xFFF2F1F4),
  textSecondary: Color(0xFFB9B7BE),
  textMuted: Color(0xFF7E7C86),
  borderSubtle: Color(0xFF2E2D33),
  accent: _accent,
  accentHover: Color(0xFF675CD1),
  accentMuted: Color(0xFF3A3670),
  success: Color(0xFF43B581),
  warning: Color(0xFFE2A63D),
  danger: Color(0xFFED5555),
  online: Color(0xFF43B581),
  onAccent: Colors.white,
);

const grchatLightColors = GrchatColors(
  bgApp: Color(0xFFF5F4F7),
  bgRail: Color(0xFFE7E5EA),
  bgSidebar: Color(0xFFEFEDEF),
  bgChat: Color(0xFFF5F4F7),
  surface: Color(0xFFFFFFFF),
  surfaceElevated: Color(0xFFE9E7EC),
  surfaceHover: Color(0xFFE4E2E8),
  surfaceSelected: Color(0xFFE3E1F5),
  textPrimary: Color(0xFF1B1A1D),
  textSecondary: Color(0xFF55535C),
  textMuted: Color(0xFF8E8C96),
  borderSubtle: Color(0xFFE0DEE4),
  accent: _accent,
  accentHover: Color(0xFF4A40B5),
  accentMuted: Color(0xFFDCD9F5),
  success: Color(0xFF2E9E6B),
  warning: Color(0xFFC77F1A),
  danger: Color(0xFFD64545),
  online: Color(0xFF2E9E6B),
  onAccent: Colors.white,
);

/// 4px base grid. Use these, not random values.
abstract final class GrchatSpace {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x8 = 32;
}

/// Radii: small controls 6-8, rows 8, composer 10-14, modal 12-16.
abstract final class GrchatRadius {
  static const double control = 8;
  static const double row = 8;
  static const double composer = 12;
  static const double modal = 14;
  static const double image = 10;
}

ThemeData _base(Brightness brightness, GrchatColors c) {
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.accent,
    onPrimary: c.onAccent,
    secondary: c.accent,
    onSecondary: c.onAccent,
    error: c.danger,
    onError: Colors.white,
    surface: c.bgChat,
    onSurface: c.textPrimary,
    surfaceContainerHighest: c.surface,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bgApp,
    dividerColor: c.borderSubtle,
    extensions: [c],
  );
}

final grchatDark = _base(Brightness.dark, grchatDarkColors);
final grchatLight = _base(Brightness.light, grchatLightColors);
