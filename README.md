# LiveContainer + SideStore + XrayRust Proxy Tweak

Нативный прокси-твик на базе сверхлёгкого ядра **xray-rust** (`aimalygin/xray-rust-mobile`), автоматически встраиваемый в последнюю ночную сборку `LiveContainer+SideStore` через GitHub Actions — **без `NEPacketTunnelProvider` и без VPN entitlements**.

## Быстрый старт (4 шага)

1. **Создайте новый репозиторий на GitHub** (публичный или приватный) и распакуйте в него этот архив.
2. **Залейте файлы в ветку `main`:**
   ```bash
   git init -b main
   git add .
   git commit -m "Initial LiveContainer+SideStore+XrayRust build"
   git remote add origin https://github.com/<ВАШ_НИК>/<ВАШ_РЕПО>.git
   git push -u origin main
   ```
3. **Дождитесь завершения workflow** во вкладке **Actions** (или нажмите *Run workflow* вручную). GitHub Actions сам скачает `XrayRust.xcframework` и свежий `LiveContainer+SideStore.ipa`, соберёт `LCProxyTweak.dylib` под `arm64-apple-ios15.0` и пропатчит IPA.
4. **Скачайте `LiveContainer+SideStore+XrayRust.ipa`** из раздела **Releases** (или Artifacts) и установите на iPhone через SideStore / Impactor / iloader с бесплатным Apple ID.

## Управление на iPhone
- Полупрозрачная плавающая кнопка **XR** перетаскивается в любую точку экрана и запоминает позицию.
- **Тройной тап тремя пальцами** скрывает или возвращает плавающую кнопку.
- Поддерживаются обычные подписки (Base64/URI), JSON-подписки (Xray / sing-box) и вставка одиночных JSON-ключей с автоматической конвертацией в чистый стандартный URI.
