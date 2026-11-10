import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shift_tracker/main.dart';

Future<SharedPreferences> _prefs([Map<String, Object> values = const <String, Object>{}]) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

/// Поднимает приложение на узком экране и запускает цикл с 1 января текущего года.
Future<void> _pumpWithCycle(WidgetTester tester, {Size size = const Size(390 * 3, 844 * 3)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(ShiftsApp(prefs: await _prefs()));
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining('Цикл на'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Дневная (1/2)'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('main screen renders on narrow phone', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ShiftsApp(prefs: await _prefs()));
    await tester.pumpAndSettle();

    expect(find.text('Мои смены'), findsOneWidget);
    expect(find.textContaining('Цикл на'), findsOneWidget);
    expect(find.text('Весь месяц'), findsOneWidget);
  });

  testWidgets('start cycle, recalc summary and periods', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final SharedPreferences prefs = await _prefs();
    await tester.pumpWidget(ShiftsApp(prefs: prefs));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Цикл на'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Дневная (1/2)'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Дней:'), findsOneWidget);

    await tester.tap(find.text('1–15 (Аванс)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Аванс'), findsWidgets);

    await tester.tap(find.text('16–конец'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Зарплата'), findsOneWidget);

    await tester.tap(find.text('Весь месяц'));
    await tester.pumpAndSettle();

    final String? cycles = prefs.getString('shifts.cycles.v1');
    expect(cycles, isNotNull);
    expect(cycles, contains('startShiftIndex'));
  });

  testWidgets('day dialog sets and resets override', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final SharedPreferences prefs = await _prefs();
    await tester.pumpWidget(ShiftsApp(prefs: prefs));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Цикл на'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Дневная (1/2)'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('3').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('🏖️ Отпуск'), findsWidgets);

    await tester.tap(find.text('🏖️ Отпуск').last);
    await tester.pumpAndSettle();
    expect(prefs.getString('shifts.overrides.v1'), contains('VACATION'));

    await tester.tap(find.text('3').first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Сбросить к исходному графику'));
    await tester.pumpAndSettle();
    expect(prefs.getString('shifts.overrides.v1'), isNot(contains('VACATION')));
  });

  testWidgets('settings sheet saves rates and indexes salary', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final SharedPreferences prefs = await _prefs();
    await tester.pumpWidget(ShiftsApp(prefs: prefs));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Настройки'), findsOneWidget);

    await tester.tap(find.text('💾 Сохранить'));
    await tester.pumpAndSettle();
    expect(prefs.getString('shifts.ratesHistory.v1'), isNotNull);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('📈 Повысить оклад'));
    await tester.pumpAndSettle();

    final String? history = prefs.getString('shifts.ratesHistory.v1');
    expect(history, isNotNull);
    expect(history, contains('dayRate'));
  });

  testWidgets('swipe left and right switches months', (WidgetTester tester) async {
    await _pumpWithCycle(tester);

    final DateTime base = firstDayOfMonth(todayUtc());
    expect(find.text(formatMonthRu(base)), findsOneWidget);

    await tester.dragFrom(tester.getCenter(find.byType(GridView).first), const Offset(-220, 0));
    await tester.pumpAndSettle();
    expect(find.text(formatMonthRu(DateTime.utc(base.year, base.month + 1, 1))), findsOneWidget);

    await tester.dragFrom(tester.getCenter(find.byType(GridView).first), const Offset(220, 0));
    await tester.pumpAndSettle();
    expect(find.text(formatMonthRu(base)), findsOneWidget);

    await tester.dragFrom(tester.getCenter(find.byType(GridView).first), const Offset(220, 0));
    await tester.pumpAndSettle();
    expect(find.text(formatMonthRu(DateTime.utc(base.year, base.month - 1, 1))), findsOneWidget);
  });

  testWidgets('year overview shows 12 month cards with sums', (WidgetTester tester) async {
    await _pumpWithCycle(tester);

    await tester.tap(find.byIcon(Icons.bar_chart_rounded));
    await tester.pumpAndSettle();

    expect(find.textContaining('Сводка за'), findsOneWidget);
    for (final String month in kMonthsNominative) {
      expect(find.text(month), findsWidgets, reason: 'нет карточки месяца $month');
    }
    expect(find.textContaining('Месяцев в графике: 12 из 12'), findsOneWidget);
  });

  testWidgets('year card opens month and period syncs back', (WidgetTester tester) async {
    await _pumpWithCycle(tester);

    await tester.tap(find.byIcon(Icons.bar_chart_rounded));
    await tester.pumpAndSettle();

    await tester.tap(find.text('1–15 (Аванс)'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Март'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Март'));
    await tester.pumpAndSettle();

    final int year = todayUtc().year;
    expect(find.text(formatMonthRu(DateTime.utc(year, 3, 1))), findsOneWidget);
    expect(find.textContaining('Аванс'), findsWidgets);
  });

  testWidgets('year overview swipes between years', (WidgetTester tester) async {
    await _pumpWithCycle(tester);

    await tester.tap(find.byIcon(Icons.bar_chart_rounded));
    await tester.pumpAndSettle();

    final int year = todayUtc().year;
    expect(find.text('Сводка за $year г.'), findsOneWidget);

    await tester.dragFrom(tester.getCenter(find.textContaining('Итого за')), const Offset(-220, 0));
    await tester.pumpAndSettle();
    expect(find.text('Сводка за ${year + 1} г.'), findsOneWidget);
    expect(find.textContaining('цикл на ${year + 1} г. не запущен'), findsOneWidget);

    await tester.dragFrom(tester.getCenter(find.textContaining('Итого за')), const Offset(220, 0));
    await tester.pumpAndSettle();
    expect(find.text('Сводка за $year г.'), findsOneWidget);
  });

  testWidgets('no layout overflow on 320px width', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320 * 2, 568 * 2);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ShiftsApp(prefs: await _prefs()));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Цикл на'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Дневная (1/2)'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.bar_chart_rounded));
    await tester.pumpAndSettle();
    expect(find.textContaining('Сводка за'), findsOneWidget);

    await tester.ensureVisible(find.text('Ноябрь'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ноябрь'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Дней:'), findsOneWidget);
  });
}