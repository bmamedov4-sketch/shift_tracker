import 'dart:convert';

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Ключи локального хранилища (JSON-строки)
// ---------------------------------------------------------------------------
const String _kStoreOverrides = 'shifts.overrides.v1';
const String _kStoreCycles = 'shifts.cycles.v1';
const String _kStoreRates = 'shifts.rates.v1';
const String _kStoreRatesHistory = 'shifts.ratesHistory.v1';
const String _kStoreDayColor = 'shifts.dayColor.v1';
const String _kStoreNightColor = 'shifts.nightColor.v1';
const String kStoreThemeMode = 'shifts.themeMode.v1';

// ---------------------------------------------------------------------------
// Русские подписи (собственные легковесные хелперы, без intl)
// ---------------------------------------------------------------------------
const List<String> kWeekdaysShort = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
const List<String> kWeekdaysFull = [
  'понедельник',
  'вторник',
  'среда',
  'четверг',
  'пятница',
  'суббота',
  'воскресенье',
];
const List<String> kMonthsGenitive = [
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];
const List<String> kMonthsNominative = [
  'Январь',
  'Февраль',
  'Март',
  'Апрель',
  'Май',
  'Июнь',
  'Июль',
  'Август',
  'Сентябрь',
  'Октябрь',
  'Ноябрь',
  'Декабрь',
];

// ---------------------------------------------------------------------------
// Хелперы дат (всегда UTC, чтобы исключить DST-баги при difference().inDays)
// ---------------------------------------------------------------------------
String two(int v) => v.toString().padLeft(2, '0');
String four(int v) => v.toString().padLeft(4, '0');

DateTime utcDay(int year, int month, int day) => DateTime.utc(year, month, day);

DateTime normalizeDay(DateTime date) => DateTime.utc(date.year, date.month, date.day);

/// Ключ дня: "YYYY-MM-DD".
String dateKey(DateTime date) => '${four(date.year)}-${two(date.month)}-${two(date.day)}';

/// Ключ месяца индексации: "YYYY-MM".
String monthKey(int year, int month) => '${four(year)}-${two(month)}';

DateTime parseDateKey(String key) {
  final parts = key.split('-');
  if (parts.length != 3) return DateTime.utc(1970, 1, 1);
  return DateTime.utc(int.tryParse(parts[0]) ?? 1970, int.tryParse(parts[1]) ?? 1, int.tryParse(parts[2]) ?? 1);
}

DateTime firstDayOfMonth(DateTime date) => DateTime.utc(date.year, date.month, 1);

int daysInMonth(int year, int month) => DateTime.utc(year, month + 1, 0).day;

bool isSameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

DateTime todayUtc() {
  final now = DateTime.now();
  return DateTime.utc(now.year, now.month, now.day);
}

String formatDateRu(DateTime date) => '${date.day} ${kMonthsGenitive[date.month - 1]} ${date.year} г.';

String formatDateRuShort(DateTime date) => '${date.day} ${kMonthsGenitive[date.month - 1]}';

String formatMonthRu(DateTime date) => '${kMonthsNominative[date.month - 1]} ${date.year}';

// ---------------------------------------------------------------------------
// Хелперы чисел (разделители тысяч пробелом)
// ---------------------------------------------------------------------------
String groupThousands(double value, {int decimals = 0}) {
  final bool negative = value < 0;
  final String raw = value.abs().toStringAsFixed(decimals);
  final List<String> parts = raw.split('.');
  final String intPart = parts[0];
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(intPart[i]);
  }
  String result = buffer.toString();
  if (parts.length > 1) result = '$result.${parts[1]}';
  return negative ? '-$result' : result;
}

bool _isWhole(double value) => (value - value.roundToDouble()).abs() < 0.005;

String formatMoney(double value) => '${groupThousands(value, decimals: _isWhole(value) ? 0 : 2)} ₽';

String formatRate(double value) => groupThousands(value, decimals: _isWhole(value) ? 0 : 2);

String formatHours(double value) {
  final bool whole = (value - value.roundToDouble()).abs() < 0.05;
  return whole ? groupThousands(value.roundToDouble()) : groupThousands(value, decimals: 1);
}

/// Число без пробелов — для TextField.
String plainNumber(double value) => _isWhole(value) ? value.toStringAsFixed(0) : value.toStringAsFixed(2);

double parseDoubleText(String text, double fallback) {
  final String cleaned = text.replaceAll(',', '.').replaceAll(' ', '').trim();
  if (cleaned.isEmpty) return fallback;
  final double? parsed = double.tryParse(cleaned);
  if (parsed == null || parsed.isNaN || parsed.isInfinite) return fallback;
  return parsed;
}

// ---------------------------------------------------------------------------
// Модель статуса дня
// ---------------------------------------------------------------------------
class ShiftStatus {
  const ShiftStatus({
    required this.key,
    required this.label,
    required this.short,
    this.isWork = false,
    this.isNight = false,
    this.isOvertime = false,
    this.isVacation = false,
    this.isSick = false,
    this.isManual = false,
  });

  final String key;
  final String label;
  final String short;
  final bool isWork;
  final bool isNight;
  final bool isOvertime;
  final bool isVacation;
  final bool isSick;

  /// true — статус ставится вручную (переопределение графика).
  final bool isManual;
}

/// Реестр статусов.
class St {
  static const ShiftStatus none = ShiftStatus(key: 'NONE', label: 'Не задано', short: '—');

  static const ShiftStatus day1 = ShiftStatus(key: 'DAY_1', label: 'Дневная (1/2)', short: '☀️ День', isWork: true);
  static const ShiftStatus day2 = ShiftStatus(key: 'DAY_2', label: 'Дневная (2/2)', short: '☀️ День', isWork: true);
  static const ShiftStatus off1 = ShiftStatus(key: 'OFF_1', label: 'Выходной', short: '☕ Вых');
  static const ShiftStatus night1 =
      ShiftStatus(key: 'NIGHT_1', label: 'Ночная (1/2)', short: '🌙 Ночь', isWork: true, isNight: true);
  static const ShiftStatus night2 =
      ShiftStatus(key: 'NIGHT_2', label: 'Ночная (2/2)', short: '🌙 Ночь', isWork: true, isNight: true);
  static const ShiftStatus sleep = ShiftStatus(key: 'SLEEP', label: 'Отсыпной', short: '🛌 Отсып');
  static const ShiftStatus off2 = ShiftStatus(key: 'OFF_2', label: 'Выходной (1/2)', short: '☕ Вых');
  static const ShiftStatus off3 = ShiftStatus(key: 'OFF_3', label: 'Выходной (2/2)', short: '☕ Вых');

  static const ShiftStatus overtimeDay = ShiftStatus(
    key: 'OVERTIME_DAY',
    label: 'Подработка (День)',
    short: '⭐ День+',
    isWork: true,
    isOvertime: true,
    isManual: true,
  );
  static const ShiftStatus overtimeNight = ShiftStatus(
    key: 'OVERTIME_NIGHT',
    label: 'Подработка (Ночь)',
    short: '⭐ Ночь+',
    isWork: true,
    isNight: true,
    isOvertime: true,
    isManual: true,
  );
  static const ShiftStatus vacation =
      ShiftStatus(key: 'VACATION', label: 'Отпуск', short: '🏖️ Отпуск', isVacation: true, isManual: true);
  static const ShiftStatus sick =
      ShiftStatus(key: 'SICK', label: 'Больничный', short: '💊 Больн.', isSick: true, isManual: true);
  static const ShiftStatus manualOff =
      ShiftStatus(key: 'MANUAL_OFF', label: 'Внеплановый выходной', short: '☕ Вых', isManual: true);

  /// Базовый 8-дневный цикл. Индексы 0..7.
  static const List<ShiftStatus> baseCycle = <ShiftStatus>[
    day1,
    day2,
    off1,
    night1,
    night2,
    sleep,
    off2,
    off3,
  ];

  static const List<ShiftStatus> manualStatuses = <ShiftStatus>[
    overtimeDay,
    overtimeNight,
    vacation,
    sick,
    manualOff,
  ];

  static const List<ShiftStatus> all = <ShiftStatus>[
    none,
    ...baseCycle,
    ...manualStatuses,
  ];

  static ShiftStatus byKey(String? key) {
    for (final ShiftStatus status in all) {
      if (status.key == key) return status;
    }
    return none;
  }
}

// ---------------------------------------------------------------------------
// Правило изолированного цикла (действует строго до 31 декабря своего года)
// ---------------------------------------------------------------------------
class CycleRule {
  const CycleRule({required this.startDate, required this.startShiftIndex});

  /// "YYYY-MM-DD"
  final String startDate;
  final int startShiftIndex;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'startDate': startDate,
        'startShiftIndex': startShiftIndex,
      };

  static CycleRule? fromJson(Map<String, dynamic> json) {
    final String? start = json['startDate'] as String?;
    final int? index = json['startShiftIndex'] is int
        ? json['startShiftIndex'] as int
        : int.tryParse('${json['startShiftIndex']}');
    if (start == null || index == null) return null;
    return CycleRule(startDate: start, startShiftIndex: index.clamp(0, 7));
  }
}

// ---------------------------------------------------------------------------
// Ставки оплаты
// ---------------------------------------------------------------------------
class WageRates {
  const WageRates({
    required this.dayRate,
    required this.nightRate,
    required this.vacationDaily,
    required this.sickDaily,
    required this.dayHours,
    required this.nightHours,
  });

  final double dayRate;
  final double nightRate;
  final double vacationDaily;
  final double sickDaily;
  final double dayHours;
  final double nightHours;

  static const WageRates defaults = WageRates(
    dayRate: 400.0,
    nightRate: 500.0,
    vacationDaily: 2500.0,
    sickDaily: 1800.0,
    dayHours: 11.0,
    nightHours: 11.0,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'dayRate': dayRate,
        'nightRate': nightRate,
        'vacationDaily': vacationDaily,
        'sickDaily': sickDaily,
        'dayHours': dayHours,
        'nightHours': nightHours,
      };

  static WageRates fromJson(Map<String, dynamic> json) {
    return WageRates(
      dayRate: parseDoubleText('${json['dayRate'] ?? ''}', defaults.dayRate),
      nightRate: parseDoubleText('${json['nightRate'] ?? ''}', defaults.nightRate),
      vacationDaily: parseDoubleText('${json['vacationDaily'] ?? ''}', defaults.vacationDaily),
      sickDaily: parseDoubleText('${json['sickDaily'] ?? ''}', defaults.sickDaily),
      dayHours: parseDoubleText('${json['dayHours'] ?? ''}', defaults.dayHours),
      nightHours: parseDoubleText('${json['nightHours'] ?? ''}', defaults.nightHours),
    );
  }
}

// ---------------------------------------------------------------------------
// Дизайн-система: токены палитры (iOS 18, light / dark)
// ---------------------------------------------------------------------------
final class IosPalette {
  const IosPalette({
    required this.brightness,
    required this.canvas,
    required this.card,
    required this.cardAlt,
    required this.label,
    required this.labelSecondary,
    required this.labelTertiary,
    required this.separator,
    required this.fill,
    required this.accent,
    required this.accentSoft,
    required this.accentDeep,
    required this.accentSolid,
    required this.onAccent,
    required this.segmentThumb,
    required this.today,
    required this.cycleStart,
    required this.manual,
    required this.warning,
    required this.warningSoft,
    required this.danger,
    required this.dangerSoft,
    required this.shadow,
    required this.noneBg,
    required this.noneFg,
    required this.offBg,
    required this.offFg,
  });

  final Brightness brightness;

  /// Фон экрана.
  final Color canvas;

  /// Фон карточек.
  final Color card;

  /// Альтернативный фон карточек (снекбар в тёмной теме, группы).
  final Color cardAlt;

  /// Основной текст.
  final Color label;

  /// Второстепенный текст.
  final Color labelSecondary;

  /// Третичный текст / полупрозрачные подписи.
  final Color labelTertiary;

  /// Разделители и рамки.
  final Color separator;

  /// Заливка полей ввода и неактивных сегментов.
  final Color fill;

  /// Акцент (системный синий).
  final Color accent;

  /// Полупрозрачный акцент для активных пилюль.
  final Color accentSoft;

  /// Текст и иконки на тонированной подложке [accentSoft] (повышенный контраст).
  final Color accentDeep;

  /// Плотная заливка основных кнопок; в светлой теме — #007AFF (как в iOS,
  /// ≈4.0:1 для крупного/полужирного текста), в тёмной — затемнённый #0A6CD6
  /// для контраста ≥ 4.5:1 с [onAccent].
  final Color accentSolid;

  /// Текст и иконки на [accentSolid].
  final Color onAccent;

  /// «Таблетка» активного сегмента.
  final Color segmentThumb;

  /// Обводка «сегодня».
  final Color today;

  /// Обводка старта цикла.
  final Color cycleStart;

  /// Обводка ручной правки.
  final Color manual;

  /// Предупреждающий текст.
  final Color warning;

  /// Фон предупреждающего баннера.
  final Color warningSoft;

  /// Опасное действие.
  final Color danger;

  /// Полупрозрачная подложка опасного действия.
  final Color dangerSoft;

  /// Тень карточек.
  final Color shadow;

  /// Ячейка «не задано».
  final Color noneBg;
  final Color noneFg;

  /// Ячейка «выходной».
  final Color offBg;
  final Color offFg;

  bool get isDark => brightness == Brightness.dark;

  static const IosPalette light = IosPalette(
    brightness: Brightness.light,
    canvas: Color(0xFFF2F2F7),
    card: Color(0xFFFFFFFF),
    cardAlt: Color(0xFFF7F7FA),
    label: Color(0xFF000000),
    labelSecondary: Color(0xFF8A8A8E),
    labelTertiary: Color(0xFFC4C4C8),
    separator: Color(0xFFE3E3E8),
    fill: Color(0xFFEDEDF0),
    accent: Color(0xFF007AFF),
    accentSoft: Color(0x1A007AFF),
    accentDeep: Color(0xFF0055B8),
    accentSolid: Color(0xFF007AFF),
    onAccent: Color(0xFFFFFFFF),
    segmentThumb: Color(0xFFFFFFFF),
    today: Color(0xFF007AFF),
    cycleStart: Color(0xFFAF52DE),
    manual: Color(0xFFFF9500),
    warning: Color(0xFFB25000),
    warningSoft: Color(0xFFFFF4E0),
    danger: Color(0xFFFF3B30),
    dangerSoft: Color(0x14FF3B30),
    shadow: Color(0x0F000000),
    noneBg: Color(0xFFEFF0F5),
    noneFg: Color(0xFF9AA0AE),
    offBg: Color(0xFFE8EAF1),
    offFg: Color(0xFF5A6172),
  );

  static const IosPalette dark = IosPalette(
    brightness: Brightness.dark,
    canvas: Color(0xFF000000),
    card: Color(0xFF1C1C1E),
    cardAlt: Color(0xFF2C2C2E),
    label: Color(0xFFFFFFFF),
    labelSecondary: Color(0xFF98989F),
    labelTertiary: Color(0xFF6C6C70),
    separator: Color(0xFF38383A),
    fill: Color(0xFF2C2C2E),
    accent: Color(0xFF0A84FF),
    accentSoft: Color(0x2E0A84FF),
    accentDeep: Color(0xFF0A84FF),
    accentSolid: Color(0xFF0A6CD6),
    onAccent: Color(0xFFFFFFFF),
    segmentThumb: Color(0xFF636366),
    today: Color(0xFF0A84FF),
    cycleStart: Color(0xFFBF5AF2),
    manual: Color(0xFFFF9F0A),
    warning: Color(0xFFFFB340),
    warningSoft: Color(0x332B1F0A),
    danger: Color(0xFFFF453A),
    dangerSoft: Color(0x24FF453A),
    shadow: Color(0x00000000),
    noneBg: Color(0xFF232326),
    noneFg: Color(0xFF8A8A8E),
    offBg: Color(0xFF2C2C2E),
    offFg: Color(0xFFB0B0B6),
  );
}

/// Палитра текущей темы.
IosPalette iosPalette(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  return theme.brightness == Brightness.dark ? IosPalette.dark : IosPalette.light;
}

/// Единый стиль карточки в духе iOS 18 inset grouped.
BoxDecoration iosCardDecoration(IosPalette p, {double radius = 22}) {
  return BoxDecoration(
    color: p.card,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: p.separator, width: 0.6),
    boxShadow: p.shadow == Colors.transparent
        ? null
        : <BoxShadow>[
            BoxShadow(color: p.shadow, blurRadius: 20, offset: const Offset(0, 6)),
          ],
  );
}

// ---------------------------------------------------------------------------
// Цветовые палитры (фон + текст) для ячеек календаря
// ---------------------------------------------------------------------------
class ShiftPalette {
  const ShiftPalette(this.background, this.foreground, {this.darkBackground, this.darkForeground});
  final Color background;
  final Color foreground;
  final Color? darkBackground;
  final Color? darkForeground;

  Color bgFor(bool dark) => dark ? (darkBackground ?? background) : background;
  Color fgFor(bool dark) => dark ? (darkForeground ?? foreground) : foreground;
}

const List<ShiftPalette> kDayPalettes = <ShiftPalette>[
  ShiftPalette(
    Color(0xFFFFF1C9),
    Color(0xFF8A5A00),
    darkBackground: Color(0xFF3A2E14),
    darkForeground: Color(0xFFFFD479),
  ),
  ShiftPalette(
    Color(0xFFDDF3DF),
    Color(0xFF1B6B33),
    darkBackground: Color(0xFF162E1C),
    darkForeground: Color(0xFF7FE39B),
  ),
  ShiftPalette(
    Color(0xFFDCE9FF),
    Color(0xFF17427F),
    darkBackground: Color(0xFF152438),
    darkForeground: Color(0xFF87BDFF),
  ),
  ShiftPalette(
    Color(0xFFFFE3D6),
    Color(0xFF8C3B12),
    darkBackground: Color(0xFF3A2115),
    darkForeground: Color(0xFFFFB48A),
  ),
  ShiftPalette(
    Color(0xFFEADDFF),
    Color(0xFF4B2A85),
    darkBackground: Color(0xFF27203A),
    darkForeground: Color(0xFFC6AAFF),
  ),
  ShiftPalette(
    Color(0xFFD6F1F5),
    Color(0xFF0F5A66),
    darkBackground: Color(0xFF102B2E),
    darkForeground: Color(0xFF7FDCE8),
  ),
];

const List<ShiftPalette> kNightPalettes = <ShiftPalette>[
  ShiftPalette(
    Color(0xFF2A3161),
    Color(0xFFDCE3FF),
    darkBackground: Color(0xFF232944),
    darkForeground: Color(0xFFDCE3FF),
  ),
  ShiftPalette(
    Color(0xFF1F2A44),
    Color(0xFFBFCFF7),
    darkBackground: Color(0xFF1A2336),
    darkForeground: Color(0xFFBFCFF7),
  ),
  ShiftPalette(
    Color(0xFF3B2B57),
    Color(0xFFE7D9FF),
    darkBackground: Color(0xFF2C2140),
    darkForeground: Color(0xFFE7D9FF),
  ),
  ShiftPalette(
    Color(0xFF1D3B33),
    Color(0xFFC5F0DF),
    darkBackground: Color(0xFF162E28),
    darkForeground: Color(0xFFC5F0DF),
  ),
  ShiftPalette(
    Color(0xFF23303B),
    Color(0xFFB9E3F7),
    darkBackground: Color(0xFF1B2630),
    darkForeground: Color(0xFFB9E3F7),
  ),
  ShiftPalette(
    Color(0xFF3A2A2A),
    Color(0xFFF7D9D0),
    darkBackground: Color(0xFF2E2121),
    darkForeground: Color(0xFFF7D9D0),
  ),
];

// ---------------------------------------------------------------------------
// Темы приложения (iOS 18 / Material 3)
// ---------------------------------------------------------------------------
final class AppTheme {
  const AppTheme._();

  static ThemeData light() => _build(IosPalette.light);

  static ThemeData dark() => _build(IosPalette.dark);

  static ThemeData _build(IosPalette p) {
    final ColorScheme scheme = ColorScheme.fromSeed(seedColor: p.accent, brightness: p.brightness).copyWith(
      primary: p.accent,
      surface: p.card,
      onSurface: p.label,
      error: p.danger,
      onError: Colors.white,
    );

    final ThemeData base = ThemeData(useMaterial3: true, colorScheme: scheme);

    final TextTheme textTheme = base.textTheme.copyWith(
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: p.label,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: p.label,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        fontSize: 14.5,
        letterSpacing: -0.1,
        color: p.label,
      ),
      bodySmall: base.textTheme.bodySmall?.copyWith(color: p.labelSecondary),
      labelLarge: base.textTheme.labelLarge?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: p.label,
      ),
    );

    return base.copyWith(
      scaffoldBackgroundColor: p.canvas,
      canvasColor: p.canvas,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: p.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        foregroundColor: p.label,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
          color: p.label,
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
        },
      ),
      dividerTheme: DividerThemeData(color: p.separator, thickness: 0.6, space: 0.6),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.isDark ? p.cardAlt : const Color(0xFF1C1C1E),
        contentTextStyle: const TextStyle(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalBackgroundColor: Colors.transparent,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Расчетный период
// ---------------------------------------------------------------------------
enum PeriodMode { all, firstHalf, secondHalf }

extension PeriodModeLabels on PeriodMode {
  String get shortLabel {
    switch (this) {
      case PeriodMode.all:
        return 'Весь месяц';
      case PeriodMode.firstHalf:
        return '1–15 (Аванс)';
      case PeriodMode.secondHalf:
        return '16–конец';
    }
  }

  String get summaryLabel {
    switch (this) {
      case PeriodMode.all:
        return 'Расчет: Весь месяц';
      case PeriodMode.firstHalf:
        return 'Расчет: 1–15 число (Аванс)';
      case PeriodMode.secondHalf:
        return 'Расчет: 16–30/31 число (Зарплата)';
    }
  }
}

// ---------------------------------------------------------------------------
// Итоги по периоду
// ---------------------------------------------------------------------------
class PeriodStats {
  const PeriodStats({
    required this.dayCount,
    required this.nightCount,
    required this.overtimeCount,
    required this.vacationCount,
    required this.sickCount,
    required this.hours,
    required this.shiftsMoney,
    required this.vacationMoney,
    required this.sickMoney,
  });

  final int dayCount;
  final int nightCount;
  final int overtimeCount;
  final int vacationCount;
  final int sickCount;
  final double hours;
  final double shiftsMoney;
  final double vacationMoney;
  final double sickMoney;

  double get total => shiftsMoney + vacationMoney + sickMoney;

  static const PeriodStats empty = PeriodStats(
    dayCount: 0,
    nightCount: 0,
    overtimeCount: 0,
    vacationCount: 0,
    sickCount: 0,
    hours: 0,
    shiftsMoney: 0,
    vacationMoney: 0,
    sickMoney: 0,
  );
}

// ---------------------------------------------------------------------------
// Результат действия в диалоге дня
// ---------------------------------------------------------------------------
class DayAction {
  const DayAction(this.kind, {this.statusKey});
  final String kind;
  final String? statusKey;

  static const String overrideStatus = 'override';
  static const String reset = 'reset';
  static const String startCycle = 'startCycle';
  static const String deleteStart = 'deleteStart';
}

// ---------------------------------------------------------------------------
// Точка входа
// ---------------------------------------------------------------------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  runApp(ShiftsApp(prefs: prefs));
}

class ShiftsApp extends StatefulWidget {
  const ShiftsApp({super.key, required this.prefs});

  final SharedPreferences prefs;

  @override
  State<ShiftsApp> createState() => _ShiftsAppState();
}

class _ShiftsAppState extends State<ShiftsApp> {
  ThemeMode _mode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _mode = _parseMode(widget.prefs.getString(kStoreThemeMode));
  }

  static ThemeMode _parseMode(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
      default:
        return ThemeMode.system;
    }
  }

  void _setMode(ThemeMode mode) {
    setState(() => _mode = mode);
    widget.prefs.setString(kStoreThemeMode, mode.name);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Мои смены',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _mode,
      home: ShiftsPage(
        prefs: widget.prefs,
        themeMode: _mode,
        onThemeModeChanged: _setMode,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Главный экран
// ---------------------------------------------------------------------------
class ShiftsPage extends StatefulWidget {
  const ShiftsPage({
    super.key,
    required this.prefs,
    this.themeMode = ThemeMode.system,
    this.onThemeModeChanged,
  });

  final SharedPreferences prefs;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  @override
  State<ShiftsPage> createState() => _ShiftsPageState();
}

class _ShiftsPageState extends State<ShiftsPage> {
  late final SharedPreferences _prefs = widget.prefs;

  Map<String, String> _overrides = <String, String>{};
  List<CycleRule> _cycleRules = <CycleRule>[];
  WageRates _baseRates = WageRates.defaults;
  Map<String, WageRates> _ratesHistory = <String, WageRates>{};
  int _dayColorIndex = 0;
  int _nightColorIndex = 0;
  PeriodMode _period = PeriodMode.all;
  late DateTime _visibleMonth;

  @override
  void initState() {
    super.initState();
    _visibleMonth = firstDayOfMonth(todayUtc());
    _load();
  }

  // ------------------------- Хранилище -------------------------

  void _load() {
    final String? overridesRaw = _prefs.getString(_kStoreOverrides);
    if (overridesRaw != null && overridesRaw.isNotEmpty) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(overridesRaw) as Map<String, dynamic>;
        _overrides = decoded.map<String, String>((String key, dynamic value) => MapEntry<String, String>(key, value.toString()));
      } catch (_) {
        _overrides = <String, String>{};
      }
    }

    final String? cyclesRaw = _prefs.getString(_kStoreCycles);
    if (cyclesRaw != null && cyclesRaw.isNotEmpty) {
      try {
        final List<dynamic> decoded = jsonDecode(cyclesRaw) as List<dynamic>;
        final List<CycleRule> rules = <CycleRule>[];
        for (final dynamic item in decoded) {
          if (item is Map<String, dynamic>) {
            final CycleRule? rule = CycleRule.fromJson(item);
            if (rule != null) rules.add(rule);
          }
        }
        _cycleRules = rules;
      } catch (_) {
        _cycleRules = <CycleRule>[];
      }
    }

    final String? ratesRaw = _prefs.getString(_kStoreRates);
    if (ratesRaw != null && ratesRaw.isNotEmpty) {
      try {
        _baseRates = WageRates.fromJson(jsonDecode(ratesRaw) as Map<String, dynamic>);
      } catch (_) {
        _baseRates = WageRates.defaults;
      }
    }

    final String? historyRaw = _prefs.getString(_kStoreRatesHistory);
    if (historyRaw != null && historyRaw.isNotEmpty) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(historyRaw) as Map<String, dynamic>;
        final Map<String, WageRates> history = <String, WageRates>{};
        decoded.forEach((String key, dynamic value) {
          if (value is Map<String, dynamic>) history[key] = WageRates.fromJson(value);
        });
        _ratesHistory = history;
      } catch (_) {
        _ratesHistory = <String, WageRates>{};
      }
    }

    _dayColorIndex = int.tryParse(_prefs.getString(_kStoreDayColor) ?? '') ?? 0;
    _nightColorIndex = int.tryParse(_prefs.getString(_kStoreNightColor) ?? '') ?? 0;
    if (_dayColorIndex < 0 || _dayColorIndex >= kDayPalettes.length) _dayColorIndex = 0;
    if (_nightColorIndex < 0 || _nightColorIndex >= kNightPalettes.length) _nightColorIndex = 0;
  }

  void _saveOverrides() {
    _prefs.setString(_kStoreOverrides, jsonEncode(_overrides));
  }

  void _saveCycles() {
    _prefs.setString(_kStoreCycles, jsonEncode(_cycleRules.map((CycleRule rule) => rule.toJson()).toList()));
  }

  void _saveRates() {
    _prefs.setString(_kStoreRates, jsonEncode(_baseRates.toJson()));
    final Map<String, dynamic> history = <String, dynamic>{};
    _ratesHistory.forEach((String key, WageRates value) {
      history[key] = value.toJson();
    });
    _prefs.setString(_kStoreRatesHistory, jsonEncode(history));
    _prefs.setString(_kStoreDayColor, _dayColorIndex.toString());
    _prefs.setString(_kStoreNightColor, _nightColorIndex.toString());
  }

  // ------------------------- Логика графика -------------------------

  /// Правило, действующее в конкретный день: тот же год, старт не позже дня,
  /// из подходящих — с самой поздней датой старта.
  CycleRule? _activeRuleFor(DateTime date) {
    final DateTime target = normalizeDay(date);
    CycleRule? best;
    DateTime? bestStart;
    for (final CycleRule rule in _cycleRules) {
      final DateTime start = parseDateKey(rule.startDate);
      if (start.year != target.year) continue;
      if (start.isAfter(target)) continue;
      if (bestStart == null || start.isAfter(bestStart)) {
        best = rule;
        bestStart = start;
      }
    }
    return best;
  }

  CycleRule? _cycleRuleStartingAt(DateTime date) {
    final String key = dateKey(date);
    for (final CycleRule rule in _cycleRules) {
      if (rule.startDate == key) return rule;
    }
    return null;
  }

  ShiftStatus _statusFor(DateTime date) {
    final String key = dateKey(date);
    final String? manualKey = _overrides[key];
    if (manualKey != null) return St.byKey(manualKey);
    final CycleRule? rule = _activeRuleFor(date);
    if (rule == null) return St.none;
    final DateTime target = normalizeDay(date);
    final DateTime start = parseDateKey(rule.startDate);
    final int daysDiff = target.difference(start).inDays;
    final int index = ((rule.startShiftIndex + daysDiff) % 8 + 8) % 8;
    return St.baseCycle[index];
  }

  bool _monthIsEmpty(DateTime month) {
    final int total = daysInMonth(month.year, month.month);
    for (int day = 1; day <= total; day++) {
      if (_statusFor(utcDay(month.year, month.month, day)).key != St.none.key) return false;
    }
    return true;
  }

  // ------------------------- Ставки и индексация -------------------------

  String _activeRateKey(String ym) {
    if (_ratesHistory.isEmpty) return ym;
    final List<String> keys = _ratesHistory.keys.toList()..sort();
    String? chosen;
    for (final String key in keys) {
      if (key.compareTo(ym) <= 0) chosen = key;
    }
    return chosen ?? keys.first;
  }

  WageRates _ratesForMonth(String ym) {
    if (_ratesHistory.isEmpty) return _baseRates;
    return _ratesHistory[_activeRateKey(ym)] ?? _baseRates;
  }

  // ------------------------- Расчет периода -------------------------

  bool _inPeriod(DateTime date, PeriodMode mode) {
    switch (mode) {
      case PeriodMode.all:
        return true;
      case PeriodMode.firstHalf:
        return date.day <= 15;
      case PeriodMode.secondHalf:
        return date.day >= 16;
    }
  }

  PeriodStats _statsFor(DateTime month, PeriodMode mode) {
    final WageRates rates = _ratesForMonth(monthKey(month.year, month.month));
    final int total = daysInMonth(month.year, month.month);
    int dayCount = 0;
    int nightCount = 0;
    int overtimeCount = 0;
    int vacationCount = 0;
    int sickCount = 0;

    for (int day = 1; day <= total; day++) {
      final DateTime date = utcDay(month.year, month.month, day);
      if (!_inPeriod(date, mode)) continue;
      final ShiftStatus status = _statusFor(date);
      if (status.isVacation) {
        vacationCount++;
        continue;
      }
      if (status.isSick) {
        sickCount++;
        continue;
      }
      if (!status.isWork) continue;
      if (status.isNight) {
        nightCount++;
      } else {
        dayCount++;
      }
      if (status.isOvertime) overtimeCount++;
    }

    final double shiftsMoney =
        (dayCount * rates.dayHours * rates.dayRate) + (nightCount * rates.nightHours * rates.nightRate);
    final double vacationMoney = vacationCount * rates.vacationDaily;
    final double sickMoney = sickCount * rates.sickDaily;

    return PeriodStats(
      dayCount: dayCount,
      nightCount: nightCount,
      overtimeCount: overtimeCount,
      vacationCount: vacationCount,
      sickCount: sickCount,
      hours: (dayCount * rates.dayHours) + (nightCount * rates.nightHours),
      shiftsMoney: shiftsMoney,
      vacationMoney: vacationMoney,
      sickMoney: sickMoney,
    );
  }

  /// Сводка по 12 месяцам года для выбранного расчетного периода.
  List<MonthSummary> _monthSummaries(int year, PeriodMode mode) {
    final DateTime today = todayUtc();
    return List<MonthSummary>.generate(12, (int index) {
      final DateTime month = utcDay(year, index + 1, 1);
      return MonthSummary(
        month: month,
        stats: _statsFor(month, mode),
        isActive: !_monthIsEmpty(month),
        isCurrent: month.year == today.year && month.month == today.month,
      );
    });
  }

  // ------------------------- Навигация по месяцам -------------------------

  void _shiftMonth(int delta) {
    setState(() => _visibleMonth = DateTime.utc(_visibleMonth.year, _visibleMonth.month + delta, 1));
  }

  void _openYearOverview() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext routeContext) => YearOverviewPage(
          initialYear: _visibleMonth.year,
          initialPeriod: _period,
          buildMonths: _monthSummaries,
          onPeriodChanged: (PeriodMode mode) {
            if (!mounted) return;
            setState(() => _period = mode);
          },
          onMonthSelected: (DateTime month) {
            if (!mounted) return;
            setState(() => _visibleMonth = firstDayOfMonth(month));
          },
          onStartYearCycle: (int year) => _pickCycleShift(
            utcDay(year, 1, 1),
            title: 'Старт цикла с 1 января $year г.',
          ),
        ),
      ),
    );
  }

  // ------------------------- Вспомогательное -------------------------

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  ShiftPalette _paletteFor(ShiftStatus status, bool dark) {
    if (status.isNight) return kNightPalettes[_nightColorIndex];
    if (status.isWork) return kDayPalettes[_dayColorIndex];
    if (status.isVacation) {
      return dark
          ? const ShiftPalette(Color(0xFFDFF5E1), Color(0xFF1B6B33), darkBackground: Color(0xFF16301D), darkForeground: Color(0xFF7FE39B))
          : const ShiftPalette(Color(0xFFDFF5E1), Color(0xFF1B6B33));
    }
    if (status.isSick) {
      return dark
          ? const ShiftPalette(Color(0xFFFDE4E4), Color(0xFF9B1C1C), darkBackground: Color(0xFF3A1A1A), darkForeground: Color(0xFFFF9C9C))
          : const ShiftPalette(Color(0xFFFDE4E4), Color(0xFF9B1C1C));
    }
    final IosPalette p = dark ? IosPalette.dark : IosPalette.light;
    if (status.key == St.none.key) return ShiftPalette(p.noneBg, p.noneFg);
    return ShiftPalette(p.offBg, p.offFg);
  }

  // ------------------------- Построение UI -------------------------

  @override
  Widget build(BuildContext context) {
    final IosPalette p = iosPalette(context);
    final PeriodStats stats = _statsFor(_visibleMonth, _period);
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: p.canvas,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarBrightness: p.isDark ? Brightness.dark : Brightness.light,
          statusBarIconBrightness: p.isDark ? Brightness.light : Brightness.dark,
          statusBarColor: Colors.transparent,
        ),
        title: Text(
          'Мои смены',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.4, color: p.label),
        ),
        actions: <Widget>[
          TextButton.icon(
            onPressed: _openYearCycleDialog,
            style: TextButton.styleFrom(
              backgroundColor: p.accentSoft,
              foregroundColor: p.accentDeep,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: const StadiumBorder(),
              textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            icon: const Icon(Icons.add_rounded, size: 16),
            label: const Text('Цикл'),
          ),
          const SizedBox(width: 8),
          _appBarIcon(
            icon: Icons.bar_chart_rounded,
            tooltip: 'Сводка за год',
            onPressed: _openYearOverview,
            p: p,
          ),
          const SizedBox(width: 8),
          _appBarIcon(
            icon: Icons.settings_outlined,
            tooltip: 'Настройки',
            onPressed: _openSettingsSheet,
            p: p,
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: SwipeArea(
        onSwipeLeft: () => _shiftMonth(1),
        onSwipeRight: () => _shiftMonth(-1),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
          children: <Widget>[
            _buildMonthHeader(),
            if (_monthIsEmpty(_visibleMonth)) ...<Widget>[
              _buildInactiveBanner(),
              const SizedBox(height: 12),
            ] else
              const SizedBox(height: 4),
            _buildSummaryCard(stats),
            const SizedBox(height: 12),
            _buildCalendarCard(),
            const SizedBox(height: 12),
            _buildLegend(),
          ],
        ),
      ),
    );
  }

  /// Компактная иконка в «плитке» для AppBar.
  Widget _appBarIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    required IosPalette p,
  }) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(11)),
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        iconSize: 18,
        color: p.label,
        constraints: const BoxConstraints(),
        icon: Icon(icon),
      ),
    );
  }

  /// Круглая кнопка-иконка (навигация по месяцам, закрытие шторки).
  Widget _circleButton(IconData icon, {VoidCallback? onTap, double size = 32, IosPalette? palette}) {
    final IosPalette p = palette ?? iosPalette(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: p.fill, shape: BoxShape.circle),
        child: Icon(icon, size: 18, color: p.labelSecondary),
      ),
    );
  }

  Widget _buildMonthHeader() {
    final IosPalette p = iosPalette(context);
    final DateTime today = todayUtc();
    final bool showToday = _visibleMonth.year != today.year || _visibleMonth.month != today.month;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openYearOverview,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    formatMonthRu(_visibleMonth),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.9,
                      color: p.label,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _cycleRules.isEmpty
                        ? 'Цикл не задан • свайп ← →'
                        : 'Точек старта: ${_cycleRules.where((CycleRule r) => parseDateKey(r.startDate).year == _visibleMonth.year).length} • свайп ← →',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: p.labelSecondary),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (showToday) ...<Widget>[
            Flexible(
              child: Semantics(
                button: true,
                label: 'Текущий месяц',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _visibleMonth = firstDayOfMonth(todayUtc())),
                  child: Container(
                    height: 34,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: p.accentSoft,
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'Сегодня',
                        maxLines: 1,
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: p.accentDeep),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          _circleButton(Icons.chevron_left_rounded, onTap: () => _shiftMonth(-1), palette: p),
          const SizedBox(width: 8),
          _circleButton(Icons.chevron_right_rounded, onTap: () => _shiftMonth(1), palette: p),
        ],
      ),
    );
  }

  Widget _buildInactiveBanner() {
    final IosPalette p = iosPalette(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _pickCycleShift(
        utcDay(_visibleMonth.year, 1, 1),
        title: 'Старт цикла с 1 января ${_visibleMonth.year} г.',
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: p.warningSoft,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: p.warning.withValues(alpha: 0.25), width: 0.8),
        ),
        child: Row(
          children: <Widget>[
            const Text('📅', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Цикл на ${_visibleMonth.year} г. не запущен. Нажмите, чтобы начать с 1 янв.',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: p.warning, height: 1.25),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(PeriodStats stats) {
    final bool hasExtras = stats.overtimeCount > 0 || stats.vacationCount > 0 || stats.sickCount > 0;
    final WageRates rates = _ratesForMonth(monthKey(_visibleMonth.year, _visibleMonth.month));
    final IosPalette p = iosPalette(context);
    final List<FontFeature> tabular = const <FontFeature>[FontFeature.tabularFigures()];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: iosCardDecoration(p),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          PeriodTabs(
            value: _period,
            onChanged: (PeriodMode mode) => setState(() => _period = mode),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _period.summaryLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                        color: p.labelSecondary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        formatMoney(stats.total),
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -1,
                          color: p.label,
                          fontFeatures: tabular,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    '${formatHours(stats.hours)} ч',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: p.label,
                      fontFeatures: tabular,
                    ),
                  ),
                  Text('часов', style: TextStyle(fontSize: 11, color: p.labelTertiary)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(height: 0.6, color: p.separator),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _chip('☀️ Дней: ${stats.dayCount}', p),
              _chip('🌙 Ночей: ${stats.nightCount}', p),
            ],
          ),
          if (hasExtras) ...<Widget>[
            const SizedBox(height: 12),
            if (stats.overtimeCount > 0) _extraRow('⭐ Подработок', '${stats.overtimeCount}', p),
            if (stats.vacationCount > 0)
              _extraRow('🏖️ Отпуск: ${stats.vacationCount} дн.', formatMoney(stats.vacationMoney), p),
            if (stats.sickCount > 0)
              _extraRow('💊 Больничный: ${stats.sickCount} дн.', formatMoney(stats.sickMoney), p),
          ],
          const SizedBox(height: 10),
          Text(
            'Ставки: ${formatRate(rates.dayRate)} / ${formatRate(rates.nightRate)} ₽/ч • индексация ${_activeRateKey(monthKey(_visibleMonth.year, _visibleMonth.month))}',
            style: TextStyle(fontSize: 11.5, color: p.labelTertiary, height: 1.25),
          ),
        ],
      ),
    );
  }

  /// Компактная «пилюля» со статистикой.
  Widget _chip(String text, IosPalette p) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(100)),
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: p.label,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  Widget _extraRow(String label, String amount, IosPalette p) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: p.labelSecondary),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            amount,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: p.label,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarCard() {
    final int year = _visibleMonth.year;
    final int month = _visibleMonth.month;
    final int leading = DateTime.utc(year, month, 1).weekday - 1;
    final int total = daysInMonth(year, month);
    final IosPalette p = iosPalette(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: iosCardDecoration(p),
      child: Column(
        children: <Widget>[
          Row(
            children: List<Widget>.generate(kWeekdaysShort.length, (int i) {
              final String label = kWeekdaysShort[i];
              return Expanded(
                child: Center(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                      color: i == 6 ? p.danger : p.labelSecondary,
                    ),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: leading + total,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisExtent: 66,
              crossAxisSpacing: 5,
              mainAxisSpacing: 5,
            ),
            itemBuilder: (BuildContext context, int index) {
              if (index < leading) return const SizedBox.shrink();
              return _buildDayCell(utcDay(year, month, index - leading + 1));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDayCell(DateTime date) {
    final IosPalette p = iosPalette(context);
    final bool dark = p.isDark;
    final ShiftStatus status = _statusFor(date);
    final ShiftPalette palette = _paletteFor(status, dark);
    final bool isToday = isSameDay(date, todayUtc());
    final bool isCycleStart = _cycleRuleStartingAt(date) != null;
    final bool isManual = _overrides.containsKey(dateKey(date));

    Color borderColor = p.separator;
    double borderWidth = 0;
    if (isToday) {
      borderColor = p.today;
      borderWidth = 2;
    } else if (isCycleStart) {
      borderColor = p.cycleStart;
      borderWidth = 2;
    } else if (isManual) {
      borderColor = p.manual;
      borderWidth = 1.5;
    }

    final Widget cell = Container(
      decoration: BoxDecoration(
        color: palette.bgFor(dark),
        borderRadius: BorderRadius.circular(14),
        border: borderWidth > 0 ? Border.all(color: borderColor, width: borderWidth) : null,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Text(
            '${date.day}',
            maxLines: 1,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: palette.fgFor(dark),
              height: 1,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                status.short,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  color: palette.fgFor(dark).withValues(alpha: 0.85),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openDayDialog(date),
      child: _inPeriod(date, _period) ? cell : Opacity(opacity: 0.32, child: cell),
    );
  }

  Widget _buildLegend() {
    final IosPalette p = iosPalette(context);
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        spacing: 14,
        runSpacing: 8,
        children: <Widget>[
          _legendDot(p.today, 'сегодня', p),
          _legendDot(p.cycleStart, 'старт цикла', p),
          _legendDot(p.manual, 'ручная правка', p),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label, IosPalette p) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: p.labelSecondary)),
      ],
    );
  }

  // ------------------------- Диалог дня -------------------------

  Future<void> _openDayDialog(DateTime date) async {
    final IosPalette pagePalette = iosPalette(context);
    final bool dark = pagePalette.isDark;
    final ShiftStatus status = _statusFor(date);
    final bool hasOverride = _overrides.containsKey(dateKey(date));
    final CycleRule? startRule = _cycleRuleStartingAt(date);
    final ShiftPalette palette = _paletteFor(status, dark);

    final DayAction? action = await showDialog<DayAction>(
      context: context,
      builder: (BuildContext ctx) {
        final IosPalette p = iosPalette(ctx);
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: p.fill,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              formatDateRu(date),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: p.label,
                                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              status.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: p.labelSecondary),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: palette.bgFor(dark),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _sectionTitle('Быстрая установка', p),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(child: _quickAction(ctx, St.overtimeDay, '☀️ Подр. День', date)),
                    const SizedBox(width: 8),
                    Expanded(child: _quickAction(ctx, St.overtimeNight, '🌙 Подр. Ночь', date)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(child: _quickAction(ctx, St.vacation, '🏖️ Отпуск', date)),
                    const SizedBox(width: 8),
                    Expanded(child: _quickAction(ctx, St.sick, '💊 Больничный', date)),
                  ],
                ),
                const SizedBox(height: 8),
                _quickAction(ctx, St.manualOff, '☕ Внеплановый выходной', date),
                const SizedBox(height: 16),
                if (hasOverride)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _dialogButton(
                      label: '🔄 Сбросить к исходному графику',
                      background: p.accentSoft,
                      foreground: p.accent,
                      onTap: () => Navigator.of(ctx).pop(const DayAction(DayAction.reset)),
                    ),
                  ),
                _dialogButton(
                  label: '🚀 Начать новый цикл с этой даты',
                  background: p.accentSoft,
                  foreground: p.accent,
                  onTap: () => Navigator.of(ctx).pop(const DayAction(DayAction.startCycle)),
                ),
                if (startRule != null) ...<Widget>[
                  const SizedBox(height: 8),
                  _dialogButton(
                    label: '🗑️ Удалить эту точку старта',
                    background: p.dangerSoft,
                    foreground: p.danger,
                    onTap: () => Navigator.of(ctx).pop(const DayAction(DayAction.deleteStart)),
                  ),
                ],
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: TextButton.styleFrom(foregroundColor: p.accent),
              child: const Text('Закрыть'),
            ),
          ],
        );
      },
    );

    if (action == null) return;
    if (!mounted) return;

    switch (action.kind) {
      case DayAction.overrideStatus:
        setState(() => _overrides[dateKey(date)] = action.statusKey ?? St.none.key);
        _saveOverrides();
        _snack('${formatDateRuShort(date)}: ${St.byKey(action.statusKey).label}');
        break;
      case DayAction.reset:
        setState(() => _overrides.remove(dateKey(date)));
        _saveOverrides();
        _snack('${formatDateRuShort(date)}: возвращен график цикла');
        break;
      case DayAction.startCycle:
        await _pickCycleShift(date);
        break;
      case DayAction.deleteStart:
        setState(() => _cycleRules.removeWhere((CycleRule rule) => rule.startDate == dateKey(date)));
        _saveCycles();
        _snack('Точка старта ${formatDateRuShort(date)} удалена');
        break;
      default:
        break;
    }
  }

  Widget _quickAction(BuildContext dialogContext, ShiftStatus status, String label, DateTime date) {
    final bool active = _overrides[dateKey(date)] == status.key;
    final IosPalette p = iosPalette(dialogContext);
    return Material(
      color: active ? p.accentSoft : p.fill,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(dialogContext).pop(DayAction(DayAction.overrideStatus, statusKey: status.key)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 13),
          child: Center(
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: active ? p.accent : p.label,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Кнопка-действие внутри диалога дня.
  Widget _dialogButton({
    required String label,
    required Color background,
    required Color foreground,
    required VoidCallback onTap,
  }) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          height: 46,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: foreground),
          ),
        ),
      ),
    );
  }

  // ------------------------- Выбор смены для старта цикла -------------------------

  Future<void> _pickCycleShift(DateTime date, {String? title}) async {
    final int? index = await showDialog<int>(
      context: context,
      builder: (BuildContext ctx) {
        final IosPalette p = iosPalette(ctx);
        final bool dark = p.isDark;
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
          contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title ?? 'Новый цикл',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: -0.3, color: p.label),
              ),
              const SizedBox(height: 4),
              Text(
                'Какая смена выпадает на ${formatDateRu(date)}?',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: p.labelSecondary),
              ),
            ],
          ),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: List<Widget>.generate(St.baseCycle.length, (int i) {
                  final ShiftStatus status = St.baseCycle[i];
                  final ShiftPalette palette = _paletteFor(status, dark);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: p.fill,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => Navigator.of(ctx).pop(i),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: <Widget>[
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: palette.bgFor(dark),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  status.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: p.label),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: TextButton.styleFrom(foregroundColor: p.accent),
              child: const Text('Отмена'),
            ),
          ],
        );
      },
    );

    if (index == null) return;
    if (!mounted) return;

    setState(() {
      _cycleRules.removeWhere((CycleRule rule) => rule.startDate == dateKey(date));
      _cycleRules.add(CycleRule(startDate: dateKey(date), startShiftIndex: index));
    });
    _saveCycles();
    _snack('Цикл запущен с ${formatDateRuShort(date)}: ${St.baseCycle[index].label}');
  }

  void _openYearCycleDialog() {
    _pickCycleShift(
      utcDay(_visibleMonth.year, 1, 1),
      title: 'Новый цикл: 1 января ${_visibleMonth.year} г.',
    );
  }

  // ------------------------- Настройки -------------------------

  Future<void> _openSettingsSheet() async {
    final String ym = monthKey(_visibleMonth.year, _visibleMonth.month);
    final String editKey = _activeRateKey(ym);
    final WageRates rates = _ratesForMonth(ym);

    final TextEditingController dayC = TextEditingController(text: plainNumber(rates.dayRate));
    final TextEditingController nightC = TextEditingController(text: plainNumber(rates.nightRate));
    final TextEditingController vacC = TextEditingController(text: plainNumber(rates.vacationDaily));
    final TextEditingController sickC = TextEditingController(text: plainNumber(rates.sickDaily));
    final TextEditingController dayHoursC = TextEditingController(text: plainNumber(rates.dayHours));
    final TextEditingController nightHoursC = TextEditingController(text: plainNumber(rates.nightHours));

    int localDayColor = _dayColorIndex;
    int localNightColor = _nightColorIndex;
    ThemeMode localThemeMode = widget.themeMode;

    WageRates collect() {
      return WageRates(
        dayRate: parseDoubleText(dayC.text, rates.dayRate),
        nightRate: parseDoubleText(nightC.text, rates.nightRate),
        vacationDaily: parseDoubleText(vacC.text, rates.vacationDaily),
        sickDaily: parseDoubleText(sickC.text, rates.sickDaily),
        dayHours: parseDoubleText(dayHoursC.text, rates.dayHours),
        nightHours: parseDoubleText(nightHoursC.text, rates.nightHours),
      );
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setSheetState) {
            final IosPalette p = iosPalette(ctx);
            return AnimatedPadding(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: Container(
                decoration: BoxDecoration(
                  color: p.canvas,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
                  border: Border(top: BorderSide(color: p.separator, width: 0.6)),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Center(
                        child: Container(
                          width: 36,
                          height: 5,
                          decoration: BoxDecoration(
                            color: p.labelTertiary.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(100),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              'Настройки',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.5,
                                color: p.label,
                              ),
                            ),
                          ),
                          _circleButton(Icons.close_rounded, size: 30, palette: p, onTap: () => Navigator.of(ctx).pop()),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Индексация: $editKey • открытый месяц: $ym',
                        style: TextStyle(fontSize: 11.5, color: p.labelTertiary),
                      ),
                      const SizedBox(height: 18),
                      _sectionTitle('Оформление', p),
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: _themePill(
                              icon: Icons.brightness_auto_outlined,
                              label: 'Системная',
                              selected: localThemeMode == ThemeMode.system,
                              p: p,
                              onTap: () {
                                setSheetState(() => localThemeMode = ThemeMode.system);
                                widget.onThemeModeChanged?.call(ThemeMode.system);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _themePill(
                              icon: Icons.light_mode_outlined,
                              label: 'Тема светлая',
                              selected: localThemeMode == ThemeMode.light,
                              p: p,
                              onTap: () {
                                setSheetState(() => localThemeMode = ThemeMode.light);
                                widget.onThemeModeChanged?.call(ThemeMode.light);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _themePill(
                              icon: Icons.dark_mode_outlined,
                              label: 'Тема тёмная',
                              selected: localThemeMode == ThemeMode.dark,
                              p: p,
                              onTap: () {
                                setSheetState(() => localThemeMode = ThemeMode.dark);
                                widget.onThemeModeChanged?.call(ThemeMode.dark);
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _sectionTitle('Ставки', p),
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          Expanded(child: _rateField(dayC, 'Дневная, ₽/ч', p)),
                          const SizedBox(width: 10),
                          Expanded(child: _rateField(nightC, 'Ночная, ₽/ч', p)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: <Widget>[
                          Expanded(child: _rateField(vacC, 'Отпуск, ₽/день', p)),
                          const SizedBox(width: 10),
                          Expanded(child: _rateField(sickC, 'Больничный, ₽/день', p)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: <Widget>[
                          Expanded(child: _rateField(dayHoursC, 'Часов: день', p)),
                          const SizedBox(width: 10),
                          Expanded(child: _rateField(nightHoursC, 'Часов: ночь', p)),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _sectionTitle('Цвета смен', p),
                      const SizedBox(height: 10),
                      Text(
                        'Дневные смены',
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: p.labelSecondary),
                      ),
                      const SizedBox(height: 8),
                      _paletteRow(
                        palettes: kDayPalettes,
                        selectedIndex: localDayColor,
                        onSelect: (int index) => setSheetState(() => localDayColor = index),
                        p: p,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Ночные смены',
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: p.labelSecondary),
                      ),
                      const SizedBox(height: 8),
                      _paletteRow(
                        palettes: kNightPalettes,
                        selectedIndex: localNightColor,
                        onSelect: (int index) => setSheetState(() => localNightColor = index),
                        p: p,
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 50,
                        child: FilledButton(
                          onPressed: () {
                            final WageRates newRates = collect();
                            setState(() {
                              _ratesHistory[editKey] = newRates;
                              if (_ratesHistory.length == 1) _baseRates = newRates;
                              _dayColorIndex = localDayColor;
                              _nightColorIndex = localNightColor;
                            });
                            _saveRates();
                            Navigator.of(ctx).pop();
                            _snack('Ставки сохранены для индексации $editKey');
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: p.accentSolid,
                            foregroundColor: p.onAccent,
                            minimumSize: Size.fromHeight(50),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                          child: const Text('💾 Сохранить'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 50,
                        child: FilledButton(
                          onPressed: () {
                            final WageRates newRates = collect();
                            setState(() {
                              _ratesHistory[ym] = newRates;
                              if (_ratesHistory.length == 1) _baseRates = newRates;
                              _dayColorIndex = localDayColor;
                              _nightColorIndex = localNightColor;
                            });
                            _saveRates();
                            Navigator.of(ctx).pop();
                            _snack('Оклад повышен с $ym');
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: p.accentSoft,
                            foregroundColor: p.accentDeep,
                            minimumSize: Size.fromHeight(50),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                          child: const Text('📈 Повысить оклад'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '«Сохранить» обновляет ставки действующей индексации, «Повысить оклад» создает новую запись для открытого месяца.',
                        style: TextStyle(fontSize: 11, color: p.labelTertiary, height: 1.35),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    dayC.dispose();
    nightC.dispose();
    vacC.dispose();
    sickC.dispose();
    dayHoursC.dispose();
    nightHoursC.dispose();
  }

  /// Единый стиль заголовка секции настроек.
  Widget _sectionTitle(String text, IosPalette p) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
        color: p.labelSecondary,
      ),
    );
  }

  /// Пилюля выбора темы.
  Widget _themePill({
    required IconData icon,
    required String label,
    required bool selected,
    required IosPalette p,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: selected ? p.accentSoft : p.fill,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? p.accent : Colors.transparent, width: 1.2),
        ),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 15, color: selected ? p.accent : p.labelSecondary),
                const SizedBox(width: 5),
                Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: selected ? p.accent : p.labelSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _rateField(TextEditingController controller, String label, IosPalette p) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        color: p.fill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: p.labelSecondary),
          ),
          TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            ],
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: p.label,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }

  Widget _paletteRow({
    required List<ShiftPalette> palettes,
    required int selectedIndex,
    required ValueChanged<int> onSelect,
    required IosPalette p,
  }) {
    final bool dark = p.isDark;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List<Widget>.generate(palettes.length, (int index) {
        final ShiftPalette palette = palettes[index];
        final bool selected = index == selectedIndex;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onSelect(index),
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: palette.bgFor(dark),
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? p.accent : p.separator,
                width: selected ? 2 : 0.8,
              ),
            ),
            child: Center(
              child: selected
                  ? Icon(Icons.check_rounded, size: 14, color: palette.fgFor(dark))
                  : Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: palette.fgFor(dark),
                        shape: BoxShape.circle,
                      ),
                    ),
            ),
          ),
        );
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// Переключатель расчетного периода (главный экран + годовая сводка)
// ---------------------------------------------------------------------------
class PeriodTabs extends StatelessWidget {
  const PeriodTabs({super.key, required this.value, required this.onChanged});

  final PeriodMode value;
  final ValueChanged<PeriodMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final IosPalette p = iosPalette(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: p.fill,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: PeriodMode.values.map((PeriodMode mode) {
          final bool selected = mode == value;
          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(mode),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
                decoration: BoxDecoration(
                  color: selected ? p.segmentThumb : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: selected
                      ? <BoxShadow>[BoxShadow(color: p.shadow, blurRadius: 6, offset: const Offset(0, 2))]
                      : null,
                ),
                child: Text(
                  mode.shortLabel,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                    color: selected ? p.label : p.labelSecondary,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Зона горизонтального свайпа (не мешает вертикальному скроллу и тапам)
// ---------------------------------------------------------------------------
class SwipeArea extends StatefulWidget {
  const SwipeArea({
    super.key,
    required this.child,
    this.onSwipeLeft,
    this.onSwipeRight,
    this.distanceThreshold = 56,
    this.velocityThreshold = 240,
  });

  final Widget child;
  final VoidCallback? onSwipeLeft;
  final VoidCallback? onSwipeRight;
  final double distanceThreshold;
  final double velocityThreshold;

  @override
  State<SwipeArea> createState() => _SwipeAreaState();
}

class _SwipeAreaState extends State<SwipeArea> {
  double _draggedDx = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (DragStartDetails details) => _draggedDx = 0,
      onHorizontalDragUpdate: (DragUpdateDetails details) => _draggedDx += details.delta.dx,
      onHorizontalDragCancel: () => _draggedDx = 0,
      onHorizontalDragEnd: (DragEndDetails details) {
        final double velocity = details.primaryVelocity ?? 0;
        final double distance = _draggedDx;
        _draggedDx = 0;
        final bool fastEnough = velocity.abs() >= widget.velocityThreshold;
        final bool farEnough = distance.abs() >= widget.distanceThreshold;
        if (!fastEnough && !farEnough) return;
        final double direction = fastEnough ? velocity : distance;
        if (direction < 0) {
          final VoidCallback? callback = widget.onSwipeLeft;
          if (callback == null) return;
          HapticFeedback.selectionClick();
          callback();
        } else {
          final VoidCallback? callback = widget.onSwipeRight;
          if (callback == null) return;
          HapticFeedback.selectionClick();
          callback();
        }
      },
      child: widget.child,
    );
  }
}

// ---------------------------------------------------------------------------
// Сводка по одному месяцу (для годового экрана)
// ---------------------------------------------------------------------------
class MonthSummary {
  const MonthSummary({
    required this.month,
    required this.stats,
    required this.isActive,
    required this.isCurrent,
  });

  final DateTime month;
  final PeriodStats stats;
  final bool isActive;
  final bool isCurrent;
}

// ---------------------------------------------------------------------------
// Экран годовой сводки: 12 карточек месяцев с суммами
// ---------------------------------------------------------------------------
class YearOverviewPage extends StatefulWidget {
  const YearOverviewPage({
    super.key,
    required this.initialYear,
    required this.initialPeriod,
    required this.buildMonths,
    required this.onPeriodChanged,
    required this.onMonthSelected,
    required this.onStartYearCycle,
  });

  final int initialYear;
  final PeriodMode initialPeriod;
  final List<MonthSummary> Function(int year, PeriodMode period) buildMonths;
  final ValueChanged<PeriodMode> onPeriodChanged;
  final ValueChanged<DateTime> onMonthSelected;
  final Future<void> Function(int year) onStartYearCycle;

  @override
  State<YearOverviewPage> createState() => _YearOverviewPageState();
}

class _YearOverviewPageState extends State<YearOverviewPage> {
  late int _year = widget.initialYear;
  late PeriodMode _period = widget.initialPeriod;

  void _shiftYear(int delta) {
    setState(() => _year += delta);
    HapticFeedback.selectionClick();
  }

  void _changePeriod(PeriodMode mode) {
    if (mode == _period) return;
    setState(() => _period = mode);
    widget.onPeriodChanged(mode);
  }

  Future<void> _startCycle() async {
    await widget.onStartYearCycle(_year);
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final IosPalette p = iosPalette(context);
    final List<MonthSummary> months = widget.buildMonths(_year, _period);
    double totalMoney = 0;
    double totalHours = 0;
    int totalShifts = 0;
    int activeMonths = 0;
    int overtimeTotal = 0;
    int vacationTotal = 0;
    int sickTotal = 0;
    for (final MonthSummary summary in months) {
      totalMoney += summary.stats.total;
      totalHours += summary.stats.hours;
      totalShifts += summary.stats.dayCount + summary.stats.nightCount;
      overtimeTotal += summary.stats.overtimeCount;
      vacationTotal += summary.stats.vacationCount;
      sickTotal += summary.stats.sickCount;
      if (summary.isActive) activeMonths++;
    }

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: p.canvas,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarBrightness: p.isDark ? Brightness.dark : Brightness.light,
          statusBarIconBrightness: p.isDark ? Brightness.light : Brightness.dark,
          statusBarColor: Colors.transparent,
        ),
        title: Text(
          'Сводка за $_year г.',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.4, color: p.label),
        ),
      ),
      body: SwipeArea(
        onSwipeLeft: () => _shiftYear(1),
        onSwipeRight: () => _shiftYear(-1),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(bottom: 14, top: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  _navButton(Icons.chevron_left_rounded, () => _shiftYear(-1), p),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      '$_year',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1,
                        color: p.label,
                        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  _navButton(Icons.chevron_right_rounded, () => _shiftYear(1), p),
                ],
              ),
            ),
            _buildYearTotals(
              totalMoney: totalMoney,
              totalHours: totalHours,
              totalShifts: totalShifts,
              activeMonths: activeMonths,
              overtimeTotal: overtimeTotal,
              vacationTotal: vacationTotal,
              sickTotal: sickTotal,
            ),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              itemCount: months.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisExtent: 122,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemBuilder: (BuildContext context, int index) => _buildMonthCard(months[index]),
            ),
            const SizedBox(height: 14),
            Text(
              'Тап по карточке месяца открывает его в календаре. Свайп ← → переключает год.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: p.labelTertiary, height: 1.3),
            ),
          ],
        ),
      ),
    );
  }

  Widget _navButton(IconData icon, VoidCallback onTap, IosPalette p) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(color: p.fill, shape: BoxShape.circle),
        child: Icon(icon, size: 18, color: p.labelSecondary),
      ),
    );
  }

  Widget _buildYearTotals({
    required double totalMoney,
    required double totalHours,
    required int totalShifts,
    required int activeMonths,
    required int overtimeTotal,
    required int vacationTotal,
    required int sickTotal,
  }) {
    final bool yearEmpty = activeMonths == 0;
    final IosPalette p = iosPalette(context);
    final List<FontFeature> tabular = const <FontFeature>[FontFeature.tabularFigures()];
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: iosCardDecoration(p),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Итого за $_year г. • ${_period.shortLabel}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: p.labelSecondary),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    formatMoney(totalMoney),
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1,
                      color: p.label,
                      fontFeatures: tabular,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    '${formatHours(totalHours)} ч',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: p.labelSecondary,
                      fontFeatures: tabular,
                    ),
                  ),
                  Text(
                    'смен: $totalShifts',
                    style: TextStyle(fontSize: 11, color: p.labelTertiary),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(height: 0.6, color: p.separator),
          const SizedBox(height: 12),
          PeriodTabs(value: _period, onChanged: _changePeriod),
          const SizedBox(height: 12),
          Text(
            yearEmpty ? 'Нет данных: цикл на $_year г. не запущен' : 'Месяцев в графике: $activeMonths из 12',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: p.labelSecondary),
          ),
          if (overtimeTotal > 0 || vacationTotal > 0 || sickTotal > 0) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              <String>[
                if (overtimeTotal > 0) '⭐ подработок: $overtimeTotal',
                if (vacationTotal > 0) '🏖️ отпуск: $vacationTotal дн.',
                if (sickTotal > 0) '💊 больничный: $sickTotal дн.',
              ].join('   '),
              style: TextStyle(fontSize: 11.5, color: p.labelTertiary),
            ),
          ],
          if (yearEmpty) ...<Widget>[
            const SizedBox(height: 12),
            SizedBox(
              height: 46,
              child: FilledButton(
                onPressed: _startCycle,
                style: FilledButton.styleFrom(
                  backgroundColor: p.accentSolid,
                  foregroundColor: p.onAccent,
                  minimumSize: Size.fromHeight(46),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                child: Text(
                  '🚀 Запустить цикл с 1 января $_year г.',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMonthCard(MonthSummary summary) {
    final bool inactive = !summary.isActive;
    final PeriodStats stats = summary.stats;
    final IosPalette p = iosPalette(context);
    final String caption = inactive
        ? 'цикл не запущен'
        : '${stats.dayCount + stats.nightCount} смен • ${formatHours(stats.hours)} ч';

    return Opacity(
      opacity: inactive ? 0.55 : 1,
      child: Material(
        color: p.card,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () {
            widget.onMonthSelected(summary.month);
            Navigator.of(context).pop();
          },
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: summary.isCurrent ? p.accent : p.separator,
                width: summary.isCurrent ? 1.5 : 0.6,
              ),
            ),
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  kMonthsNominative[summary.month.month - 1],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.label),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    inactive ? '—' : formatMoney(stats.total),
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.6,
                      color: inactive ? p.labelSecondary : p.label,
                      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Text(
                  caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: p.labelTertiary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
