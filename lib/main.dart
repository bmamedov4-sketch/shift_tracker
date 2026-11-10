import 'dart:convert';

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
// Цветовые палитры (фон + текст) для ячеек календаря
// ---------------------------------------------------------------------------
class ShiftPalette {
  const ShiftPalette(this.background, this.foreground);
  final Color background;
  final Color foreground;
}

const List<ShiftPalette> kDayPalettes = <ShiftPalette>[
  ShiftPalette(Color(0xFFFFF1C9), Color(0xFF8A5A00)),
  ShiftPalette(Color(0xFFDDF3DF), Color(0xFF1B6B33)),
  ShiftPalette(Color(0xFFDCE9FF), Color(0xFF17427F)),
  ShiftPalette(Color(0xFFFFE3D6), Color(0xFF8C3B12)),
  ShiftPalette(Color(0xFFEADDFF), Color(0xFF4B2A85)),
  ShiftPalette(Color(0xFFD6F1F5), Color(0xFF0F5A66)),
];

const List<ShiftPalette> kNightPalettes = <ShiftPalette>[
  ShiftPalette(Color(0xFF2A3161), Color(0xFFDCE3FF)),
  ShiftPalette(Color(0xFF1F2A44), Color(0xFFBFCFF7)),
  ShiftPalette(Color(0xFF3B2B57), Color(0xFFE7D9FF)),
  ShiftPalette(Color(0xFF1D3B33), Color(0xFFC5F0DF)),
  ShiftPalette(Color(0xFF23303B), Color(0xFFB9E3F7)),
  ShiftPalette(Color(0xFF3A2A2A), Color(0xFFF7D9D0)),
];

const Color kColorToday = Color(0xFF2C6BFF);
const Color kColorCycleStart = Color(0xFF8B44D8);
const Color kColorManual = Color(0xFFFF8A1F);
const Color kColorTextMuted = Color(0xFF6B7280);
const Color kColorSurface = Color(0xFFF6F7FB);

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

class ShiftsApp extends StatelessWidget {
  const ShiftsApp({super.key, required this.prefs});

  final SharedPreferences prefs;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3F51B5));
    return MaterialApp(
      title: 'Мои смены',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: kColorSurface,
        appBarTheme: const AppBarTheme(
          backgroundColor: kColorSurface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
      ),
      home: ShiftsPage(prefs: prefs),
    );
  }
}

// ---------------------------------------------------------------------------
// Главный экран
// ---------------------------------------------------------------------------
class ShiftsPage extends StatefulWidget {
  const ShiftsPage({super.key, required this.prefs});

  final SharedPreferences prefs;

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

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      boxShadow: const <BoxShadow>[
        BoxShadow(color: Color(0x0D000000), blurRadius: 10, offset: Offset(0, 4)),
      ],
    );
  }

  ShiftPalette _paletteFor(ShiftStatus status) {
    if (status.isNight) return kNightPalettes[_nightColorIndex];
    if (status.isWork) return kDayPalettes[_dayColorIndex];
    if (status.isVacation) return const ShiftPalette(Color(0xFFDFF5E1), Color(0xFF1B6B33));
    if (status.isSick) return const ShiftPalette(Color(0xFFFDE4E4), Color(0xFF9B1C1C));
    if (status.key == St.none.key) return const ShiftPalette(Color(0xFFEFF0F5), Color(0xFF9AA0AE));
    return const ShiftPalette(Color(0xFFE8EAF1), Color(0xFF5A6172));
  }

  // ------------------------- Построение UI -------------------------

  @override
  Widget build(BuildContext context) {
    final PeriodStats stats = _statsFor(_visibleMonth, _period);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Мои смены',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
        ),
        actions: <Widget>[
          TextButton.icon(
            onPressed: _openYearCycleDialog,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.onSurface,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            icon: const Icon(Icons.add_circle_outline, size: 18),
            label: const Text('Цикл', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          IconButton(
            onPressed: _openYearOverview,
            tooltip: 'Сводка за год',
            icon: const Icon(Icons.bar_chart_rounded),
          ),
          IconButton(
            onPressed: _openSettingsSheet,
            tooltip: 'Настройки',
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 2),
        ],
      ),
      body: SwipeArea(
        onSwipeLeft: () => _shiftMonth(1),
        onSwipeRight: () => _shiftMonth(-1),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 28),
          children: <Widget>[
            _buildMonthHeader(),
            const SizedBox(height: 8),
            if (_monthIsEmpty(_visibleMonth)) ...<Widget>[
              _buildInactiveBanner(),
              const SizedBox(height: 10),
            ],
            _buildSummaryCard(stats),
            const SizedBox(height: 12),
            _buildCalendarCard(),
            const SizedBox(height: 10),
            _buildLegend(),
          ],
        ),
      ),
    );
  }

  Widget _buildMonthHeader() {
    return Row(
      children: <Widget>[
        IconButton(
          onPressed: () => _shiftMonth(-1),
          tooltip: 'Предыдущий месяц',
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Tooltip(
            message: 'Свайп ← → переключает месяцы. Тап — сводка за год.',
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _openYearOverview,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                child: Column(
                  children: <Widget>[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            formatMonthRu(_visibleMonth),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800, letterSpacing: -0.2),
                          ),
                        ),
                        const SizedBox(width: 2),
                        const Icon(Icons.unfold_more, size: 15, color: kColorTextMuted),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _cycleRules.isEmpty
                          ? 'Цикл не задан • свайп ← →'
                          : 'Точек старта: ${_cycleRules.where((CycleRule r) => parseDateKey(r.startDate).year == _visibleMonth.year).length} • свайп ← →',
                      style: const TextStyle(fontSize: 10.5, color: kColorTextMuted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        IconButton(
          onPressed: () => _shiftMonth(1),
          tooltip: 'Следующий месяц',
          icon: const Icon(Icons.chevron_right),
        ),
        IconButton(
          onPressed: () => setState(() => _visibleMonth = firstDayOfMonth(todayUtc())),
          tooltip: 'Сегодня',
          icon: const Icon(Icons.today_outlined),
        ),
      ],
    );
  }

  Widget _buildInactiveBanner() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _pickCycleShift(
          utcDay(_visibleMonth.year, 1, 1),
          title: 'Старт цикла с 1 января ${_visibleMonth.year} г.',
        ),
        child: Ink(
          decoration: BoxDecoration(
            color: const Color(0xFFFFF4E0),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFFFD79A)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '📅 Цикл на ${_visibleMonth.year} г. не начат. Нажмите для старта с 1 янв.',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: Theme.of(context).colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryCard(PeriodStats stats) {
    final bool hasExtras = stats.overtimeCount > 0 || stats.vacationCount > 0 || stats.sickCount > 0;
    final WageRates rates = _ratesForMonth(monthKey(_visibleMonth.year, _visibleMonth.month));
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _period.summaryLabel,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: kColorTextMuted),
          ),
          const SizedBox(height: 10),
          PeriodTabs(
            value: _period,
            onChanged: (PeriodMode mode) => setState(() => _period = mode),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: Text(
                  formatMoney(stats.total),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w800, letterSpacing: -0.8),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    '${formatHours(stats.hours)} ч',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                  const Text('часов', style: TextStyle(fontSize: 10, color: kColorTextMuted)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1, thickness: 0.6),
          const SizedBox(height: 10),
          Text(
            '☀️ Дней: ${stats.dayCount} • 🌙 Ночей: ${stats.nightCount}',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          if (hasExtras) ...<Widget>[
            const SizedBox(height: 6),
            if (stats.overtimeCount > 0)
              _extraRow('⭐ Подработок: ${stats.overtimeCount}'),
            if (stats.vacationCount > 0)
              _extraRow('🏖️ Отпуск: ${stats.vacationCount} дн. • ${formatMoney(stats.vacationMoney)}'),
            if (stats.sickCount > 0)
              _extraRow('💊 Больничный: ${stats.sickCount} дн. • ${formatMoney(stats.sickMoney)}'),
          ],
          const SizedBox(height: 8),
          Text(
            'Ставки: ${formatRate(rates.dayRate)} / ${formatRate(rates.nightRate)} ₽/ч • индексация ${_activeRateKey(monthKey(_visibleMonth.year, _visibleMonth.month))}',
            style: const TextStyle(fontSize: 10.5, color: kColorTextMuted),
          ),
        ],
      ),
    );
  }

  Widget _extraRow(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(text, style: const TextStyle(fontSize: 12, color: Color(0xFF444B5A), fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildCalendarCard() {
    final int year = _visibleMonth.year;
    final int month = _visibleMonth.month;
    final int leading = DateTime.utc(year, month, 1).weekday - 1;
    final int total = daysInMonth(year, month);

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
      decoration: _cardDecoration(),
      child: Column(
        children: <Widget>[
          Row(
            children: kWeekdaysShort.map((String label) {
              final bool weekend = label == 'Сб' || label == 'Вс';
              return Expanded(
                child: Center(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: weekend ? const Color(0xFFB0413E) : kColorTextMuted,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: leading + total,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisExtent: 64,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
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
    final ShiftStatus status = _statusFor(date);
    final ShiftPalette palette = _paletteFor(status);
    final bool isToday = isSameDay(date, todayUtc());
    final bool isCycleStart = _cycleRuleStartingAt(date) != null;
    final bool isManual = _overrides.containsKey(dateKey(date));

    Color borderColor = const Color(0x00000000);
    double borderWidth = 0;
    if (isToday) {
      borderColor = kColorToday;
      borderWidth = 2;
    } else if (isCycleStart) {
      borderColor = kColorCycleStart;
      borderWidth = 2;
    } else if (isManual) {
      borderColor = kColorManual;
      borderWidth = 1.5;
    }

    final Widget cell = Container(
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.circular(10),
        border: borderWidth > 0 ? Border.all(color: borderColor, width: borderWidth) : null,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Text(
            '${date.day}',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: palette.foreground, height: 1),
          ),
          const SizedBox(height: 3),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                status.short,
                maxLines: 1,
                style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: palette.foreground),
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
    Widget item(Color color, String label, {double width = 1.6}) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: color, width: width),
            ),
          ),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(fontSize: 10.5, color: kColorTextMuted)),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Wrap(
        spacing: 14,
        runSpacing: 8,
        children: <Widget>[
          item(kColorToday, 'сегодня', width: 2),
          item(kColorCycleStart, 'старт цикла', width: 2),
          item(kColorManual, 'ручная правка'),
        ],
      ),
    );
  }

  // ------------------------- Диалог дня -------------------------

  Future<void> _openDayDialog(DateTime date) async {
    final ShiftStatus status = _statusFor(date);
    final bool hasOverride = _overrides.containsKey(dateKey(date));
    final CycleRule? startRule = _cycleRuleStartingAt(date);
    final ShiftPalette palette = _paletteFor(status);

    final DayAction? action = await showDialog<DayAction>(
      context: context,
      builder: (BuildContext ctx) {
        final ColorScheme scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
          contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                formatDateRu(date),
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(
                kWeekdaysFull[date.weekday - 1],
                style: const TextStyle(fontSize: 11.5, color: kColorTextMuted, fontWeight: FontWeight.w500),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: palette.background,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          status.short,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: palette.foreground),
                        ),
                      ),
                      Text(
                        status.label,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: palette.foreground),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    Expanded(child: _quickAction(ctx, St.overtimeDay, date)),
                    const SizedBox(width: 8),
                    Expanded(child: _quickAction(ctx, St.overtimeNight, date)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(child: _quickAction(ctx, St.vacation, date)),
                    const SizedBox(width: 8),
                    Expanded(child: _quickAction(ctx, St.sick, date)),
                  ],
                ),
                const SizedBox(height: 8),
                _quickAction(ctx, St.manualOff, date),
                if (hasOverride) ...<Widget>[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(ctx).pop(const DayAction(DayAction.reset)),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(42),
                      foregroundColor: scheme.primary,
                    ),
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text('🔄 Сбросить к исходному графику', style: TextStyle(fontSize: 12.5)),
                  ),
                ],
                const Divider(height: 22),
                FilledButton.tonalIcon(
                  onPressed: () => Navigator.of(ctx).pop(const DayAction(DayAction.startCycle)),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(42)),
                  icon: const Icon(Icons.rocket_launch_outlined, size: 18),
                  label: const Text('🚀 Начать новый цикл с этой даты', style: TextStyle(fontSize: 12.5)),
                ),
                if (startRule != null) ...<Widget>[
                  const SizedBox(height: 6),
                  TextButton.icon(
                    onPressed: () => Navigator.of(ctx).pop(const DayAction(DayAction.deleteStart)),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFB3261E),
                      minimumSize: const Size.fromHeight(40),
                    ),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('🗑️ Удалить эту точку старта', style: TextStyle(fontSize: 12.5)),
                  ),
                ],
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
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

  Widget _quickAction(BuildContext dialogContext, ShiftStatus status, DateTime date) {
    final bool active = _overrides[dateKey(date)] == status.key;
    return OutlinedButton(
      onPressed: () => Navigator.of(dialogContext).pop(DayAction(DayAction.overrideStatus, statusKey: status.key)),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(40),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        side: BorderSide(
          color: active ? Theme.of(dialogContext).colorScheme.primary : const Color(0xFFD5D8E2),
          width: active ? 1.8 : 1,
        ),
        backgroundColor: active ? Theme.of(dialogContext).colorScheme.primary.withAlpha(18) : null,
      ),
      child: Text(
        status.short,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }

  // ------------------------- Выбор смены для старта цикла -------------------------

  Future<void> _pickCycleShift(DateTime date, {String? title}) async {
    final int? index = await showDialog<int>(
      context: context,
      builder: (BuildContext ctx) {
        final ColorScheme scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
          contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title ?? 'Новый цикл',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 3),
              Text(
                'Какая смена выпадает на ${formatDateRu(date)}?',
                style: const TextStyle(fontSize: 11.5, color: kColorTextMuted, fontWeight: FontWeight.w500),
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
                  return ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    leading: CircleAvatar(
                      radius: 13,
                      backgroundColor: scheme.primary.withAlpha(24),
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: scheme.primary),
                      ),
                    ),
                    title: Text(status.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    subtitle: Text(status.short, style: const TextStyle(fontSize: 11, color: kColorTextMuted)),
                    onTap: () => Navigator.of(ctx).pop(i),
                  );
                }),
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена')),
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
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setSheetState) {
            return Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Text('Настройки', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(
                      'Индексация: $editKey • открытый месяц: $ym',
                      style: const TextStyle(fontSize: 11.5, color: kColorTextMuted),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: <Widget>[
                        Expanded(child: _rateField(dayC, 'Дневная, ₽/ч')),
                        const SizedBox(width: 10),
                        Expanded(child: _rateField(nightC, 'Ночная, ₽/ч')),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        Expanded(child: _rateField(vacC, 'Отпуск, ₽/день')),
                        const SizedBox(width: 10),
                        Expanded(child: _rateField(sickC, 'Больничный, ₽/день')),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        Expanded(child: _rateField(dayHoursC, 'Часов: день')),
                        const SizedBox(width: 10),
                        Expanded(child: _rateField(nightHoursC, 'Часов: ночь')),
                      ],
                    ),
                    const SizedBox(height: 18),
                    const Text('Цвет дневных смен', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    _paletteRow(
                      palettes: kDayPalettes,
                      selectedIndex: localDayColor,
                      onSelect: (int index) => setSheetState(() => localDayColor = index),
                    ),
                    const SizedBox(height: 16),
                    const Text('Цвет ночных смен', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    _paletteRow(
                      palettes: kNightPalettes,
                      selectedIndex: localNightColor,
                      onSelect: (int index) => setSheetState(() => localNightColor = index),
                    ),
                    const SizedBox(height: 22),
                    FilledButton.icon(
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
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                      icon: const Icon(Icons.save_outlined, size: 18),
                      label: const Text('💾 Сохранить'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
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
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                      icon: const Icon(Icons.trending_up, size: 18),
                      label: const Text('📈 Повысить оклад'),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '«Сохранить» обновляет ставки действующей индексации, «Повысить оклад» создает новую запись для открытого месяца.',
                      style: TextStyle(fontSize: 10.5, color: kColorTextMuted, height: 1.35),
                    ),
                  ],
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

  Widget _rateField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
      ],
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 11.5),
        isDense: true,
        filled: true,
        fillColor: const Color(0xFFF4F5F9),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _paletteRow({
    required List<ShiftPalette> palettes,
    required int selectedIndex,
    required ValueChanged<int> onSelect,
  }) {
    return Row(
      children: List<Widget>.generate(palettes.length, (int index) {
        final ShiftPalette palette = palettes[index];
        final bool selected = index == selectedIndex;
        return Padding(
          padding: const EdgeInsets.only(right: 10),
          child: GestureDetector(
            onTap: () => onSelect(index),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: palette.background,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? const Color(0xFF1D2433) : const Color(0xFFD5D8E2),
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: selected
                  ? Icon(Icons.check, size: 20, color: palette.foreground)
                  : null,
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
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFEDEFF5),
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
                  color: selected ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: selected
                      ? const <BoxShadow>[BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 2))]
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
                    color: selected ? const Color(0xFF1D2433) : kColorTextMuted,
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
        title: Text(
          'Сводка за $_year г.',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        actions: <Widget>[
          IconButton(
            onPressed: () => _shiftYear(-1),
            tooltip: 'Предыдущий год',
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            onPressed: () => _shiftYear(1),
            tooltip: 'Следующий год',
            icon: const Icon(Icons.chevron_right),
          ),
          const SizedBox(width: 2),
        ],
      ),
      body: SwipeArea(
        onSwipeLeft: () => _shiftYear(1),
        onSwipeRight: () => _shiftYear(-1),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
          children: <Widget>[
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
                mainAxisExtent: 126,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemBuilder: (BuildContext context, int index) => _buildMonthCard(months[index]),
            ),
            const SizedBox(height: 12),
            const Text(
              'Тап по карточке месяца открывает его в календаре. Свайп ← → переключает год.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10.5, color: kColorTextMuted),
            ),
          ],
        ),
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
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0x0D000000), blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Итого за $_year г. • ${_period.shortLabel}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: kColorTextMuted),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: Text(
                  formatMoney(totalMoney),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.8),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    '${formatHours(totalHours)} ч',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                  Text(
                    'смен: $totalShifts',
                    style: const TextStyle(fontSize: 10, color: kColorTextMuted),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1, thickness: 0.6),
          const SizedBox(height: 10),
          PeriodTabs(value: _period, onChanged: _changePeriod),
          const SizedBox(height: 10),
          Text(
            yearEmpty ? 'Нет данных: цикл на $_year г. не запущен' : 'Месяцев в графике: $activeMonths из 12',
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFF444B5A)),
          ),
          if (overtimeTotal > 0 || vacationTotal > 0 || sickTotal > 0) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              <String>[
                if (overtimeTotal > 0) '⭐ подработок: $overtimeTotal',
                if (vacationTotal > 0) '🏖️ отпуск: $vacationTotal дн.',
                if (sickTotal > 0) '💊 больничный: $sickTotal дн.',
              ].join('   '),
              style: const TextStyle(fontSize: 11, color: kColorTextMuted),
            ),
          ],
          if (yearEmpty) ...<Widget>[
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: _startCycle,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(42)),
              icon: const Icon(Icons.rocket_launch_outlined, size: 18),
              label: Text('🚀 Запустить цикл с 1 января $_year г.', style: const TextStyle(fontSize: 12.5)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMonthCard(MonthSummary summary) {
    final bool inactive = !summary.isActive;
    final PeriodStats stats = summary.stats;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<String> extras = <String>[
      if (stats.overtimeCount > 0) '⭐ ${stats.overtimeCount}',
      if (stats.vacationCount > 0) '🏖️ ${stats.vacationCount}',
      if (stats.sickCount > 0) '💊 ${stats.sickCount}',
    ];

    return Opacity(
      opacity: inactive ? 0.55 : 1,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            widget.onMonthSelected(summary.month);
            Navigator.of(context).pop();
          },
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: summary.isCurrent ? scheme.primary : const Color(0x14000000),
                width: summary.isCurrent ? 2 : 1,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        kMonthsNominative[summary.month.month - 1],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
                      ),
                    ),
                    if (summary.isCurrent)
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                      ),
                  ],
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    inactive ? '—' : formatMoney(stats.total),
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                      color: inactive ? kColorTextMuted : const Color(0xFF1D2433),
                    ),
                  ),
                ),
                Text(
                  inactive
                      ? 'нет графика'
                      : '☀️ ${stats.dayCount} • 🌙 ${stats.nightCount} • ${formatHours(stats.hours)} ч',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: kColorTextMuted, fontWeight: FontWeight.w600),
                ),
                Text(
                  extras.join('  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
