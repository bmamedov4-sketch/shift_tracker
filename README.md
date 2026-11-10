# Мои смены (shift_tracker)

Приложение для учёта сменного графика 8-дневного цикла и расчёта зарплаты.
Flutter + Material 3, вся логика в `lib/main.dart`, хранение — `shared_preferences` (JSON).

```bash
flutter pub add shared_preferences
flutter run
flutter analyze   # 0 issues
flutter test      # 9 тестов
```

---

## Сборка `.ipa` (iOS)

> **Важно:** `.ipa` — это архив с приложением, собранным и подписанным тулчейном Apple.
> Он собирается **только на macOS с Xcode**. На Windows собрать `.ipa` невозможно
> физически (нет `xcodebuild`, `codesign`, SDK iOS). Единственные пути — Mac или
> macOS-раннер в облаке.

### Вариант 1. GitHub Actions (без своего Mac) — рекомендую

1. Создайте репозиторий на GitHub и запушьте проект:

   ```bash
   git remote add origin https://github.com/<ваш-логин>/shift_tracker.git
   git push -u origin master
   ```

2. Откройте репозиторий → вкладка **Actions** (Действия) → workflow
   **«Build iOS IPA + Android APK»** → кнопка **«Run workflow»** (Запустить workflow)
   → выберите `export_method = development` → **Run**.

3. Через ~10–15 минут внизу страницы запуска, в разделе **Artifacts** (Артефакты),
   появятся файлы:
   * `MyShifts-unsigned-ipa` → `MyShifts-unsigned.ipa` — **без подписи**;
   * `MyShifts-signed-ipa` → `*.ipa` — только если заданы секреты подписи (см. ниже);
   * `MyShifts-apk` → `app-release.apk` — Android-сборка (бонус).

4. **Установка неподписанного `.ipa` на iPhone** (бесплатный Apple ID):
   * Windows/Mac: [Sideloadly](https://sideloadly.io/) — подключите iPhone, перетащите
     `.ipa`, введите Apple ID → Start. Приложение живёт 7 дней, потом переподписать.
   * Mac: [AltStore](https://altstore.io/) или Xcode → **Window → Devices and Simulators**
     (Окно → Устройства и симуляторы) → «+» под «Installed Apps».

   Для бесплатного аккаунта Apple ID в настройках iPhone нужно включить
   **«Настройки» → «Основные» → «VPN и управление устройством»** и доверять
   сертификату разработчика.

5. **Подписанный `.ipa` (TestFlight / ad-hoc / App Store).** Нужен Apple Developer
   Program (99 $/год). Добавьте в **Settings → Secrets and variables → Actions**
   (Настройки → Секреты и переменные → Actions) секреты:

   | Секрет | Что это |
   |---|---|
   | `BUILD_CERTIFICATE_BASE64` | сертификат `.p12` (Apple Distribution/Development) в base64: `base64 -i cert.p12 \| pbcopy` |
   | `P12_PASSWORD` | пароль от `.p12` |
   | `KEYCHAIN_PASSWORD` | любой пароль (временная связка ключей на раннере) |
   | `PROVISIONING_PROFILE_BASE64` | профиль `.mobileprovision` в base64 |
   | `DEVELOPMENT_TEAM` | Team ID (10 символов) из [developer.apple.com](https://developer.apple.com/account) |

   Bundle ID приложения уже выставлен: **`com.ashtr.shifts`** — используйте его же
   при создании App ID и профиля.

### Вариант 2. Свой или арендованный Mac

```bash
xcode-select --install            # один раз: инструменты Xcode
sudo gem install cocoapods        # один раз: CocoaPods

./scripts/build_ipa.sh            # подписанный .ipa  → build/ios/ipa/
./scripts/build_ipa.sh unsigned   # .ipa без подписи  → build/ios/ipa-unsigned/
./scripts/build_ipa.sh app-store  # .ipa для App Store Connect
```

Если Xcode ругается на подпись:

1. Откройте `ios/Runner.xcworkspace` в Xcode.
2. Слева выберите проект **Runner** → цель **Runner** → вкладка
   **«Signing & Capabilities»** (Подпись и возможности).
3. Включите **«Automatically manage signing»** (Автоматически управлять подписью)
   и выберите свою **Team** (Команда).
4. Если команды нет: меню **Xcode → «Settings…»** (Настройки) → вкладка
   **«Accounts»** (Учётные записи) → «+» → добавьте Apple ID.

Затем вручную, при желании, через GUI Xcode:
**«Product»** (Продукт) → **«Scheme»** (Схема) → **Runner**,
далее **«Product» → «Archive»** (Продукт → Архив), после сборки —
кнопка **«Distribute App»** (Распространить приложение) → `Development` /
`Ad Hoc` / `App Store Connect`.

### Вариант 3. Облачный Mac без GitHub

Codemagic, Bitrise, MacinCloud — везде тот же сценарий: `flutter build ipa --release`.
Для Codemagic достаточно загрузить zip проекта и выбрать шаблон Flutter iOS.

---

## Сборка Android (если нужен APK)

Локально нужен Android SDK (`flutter doctor` покажет `Unable to locate Android SDK`).
Проще — тот же GitHub Actions workflow, job **«Android APK (ubuntu)»**:
готовый `app-release.apk` появится в артефактах.

```bash
flutter build apk --release     # на машине с Android SDK
```
