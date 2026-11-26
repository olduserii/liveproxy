# LiveContainer Clone + XrayRust Proxy Tweak

Нативный прокси-твик на базе сверхлёгкого ядра **xray-rust** (`aimalygin/xray-rust-mobile`), автоматически встраиваемый в чистую ночную сборку **LiveContainer** (без SideStore) в виде отдельного клона (`com.kdt.livecontainer.xray` / `LiveContainer Xray`) — **без `NEPacketTunnelProvider` и без VPN entitlements**.

## Быстрый старт

1. Отправьте изменения в ветку `main` вашего GitHub-репозитория.
2. Дождитесь завершения workflow во вкладке **Actions** (или запустите *Run workflow* вручную — можно задать свой суффикс Bundle ID и имя клона).
3. Скачайте **`LiveContainer-XrayRust-Clone.ipa`** из **Releases** (или Artifacts) и установите рядом с обычным LiveContainer.

## Управление на iPhone
- **Тройной тап двумя пальцами** в любом месте экрана (внутри LiveContainer и в любом гостевом приложении) открывает и закрывает меню управления прокси.
- Поддерживаются обычные подписки (Base64/URI), JSON-подписки (Xray / sing-box) и вставка одиночных JSON-ключей с автоматической конвертацией в чистый стандартный URI.
