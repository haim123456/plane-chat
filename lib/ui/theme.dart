import 'package:material_ui/material_ui.dart';

const kSeed = Color(0xFF2563EB); // clear sky blue

ThemeData buildTheme(Brightness b) {
  final scheme = ColorScheme.fromSeed(
    seedColor: kSeed,
    brightness: b,
    dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
  );
  final dark = b == Brightness.dark;
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: dark ? const Color(0xFF0B1220) : const Color(0xFFF3F6FC),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xFF111A2E) : Colors.white,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: dark ? const Color(0xFF141E33) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}

/// Colors used by chat bubbles, per brightness.
class ChatPalette {
  ChatPalette(BuildContext context)
      : cs = Theme.of(context).colorScheme,
        dark = Theme.of(context).brightness == Brightness.dark;
  final ColorScheme cs;
  final bool dark;

  List<Color> get mine => dark
      ? const [Color(0xFF2563EB), Color(0xFF4F46E5)]
      : const [Color(0xFF3B82F6), Color(0xFF6366F1)];
  Color get onMine => Colors.white;
  Color get theirs => dark ? const Color(0xFF1C2740) : Colors.white;
  Color get onTheirs => dark ? const Color(0xFFE6EBF5) : const Color(0xFF111827);
  Color get wallpaperA => dark ? const Color(0xFF0B1220) : const Color(0xFFEFF4FF);
  Color get wallpaperB => dark ? const Color(0xFF101A30) : const Color(0xFFF8F5FF);
  Color get delivered => const Color(0xFFA5F3FC);
}

String hhmm(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String mmss(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String dayLabel(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(d.year, d.month, d.day);
  final diff = today.difference(that).inDays;
  if (diff == 0) return 'היום';
  if (diff == 1) return 'אתמול';
  return '${d.day}.${d.month}.${d.year}';
}

bool sameDay(int a, int b) {
  final x = DateTime.fromMillisecondsSinceEpoch(a), y = DateTime.fromMillisecondsSinceEpoch(b);
  return x.year == y.year && x.month == y.month && x.day == y.day;
}
