import React, { useState } from 'react';
import { Check, Copy, Download, ArrowRight } from 'lucide-react';

interface ArchitectureViewProps {
  onDownloadZip: () => void;
  onJumpToFile: (path: string) => void;
}

const DEPLOY_COMMANDS = `unzip livecontainer-sidestore-xray-rust.zip -d lc-xray-rust
cd lc-xray-rust
git init -b main
git add .
git commit -m "Initial LiveContainer+SideStore+XrayRust build"
git remote add origin https://github.com/<ВАШ_НИК>/<ВАШ_РЕПО>.git
git push -u origin main`;

const MODULES = [
  {
    index: '01',
    title: 'Изолированный C ABI-адаптер к XrayRust.xcframework',
    file: 'tweak/LCXrayRustBridge.m',
    details:
      'Вся работа с FFI-функциями aimalygin/xray-rust-mobile вынесена в один модуль. Поддерживаются и multi-instance handle ABI, и singleton start/stop ABI с динамическим выделением свободного локального порта (127.0.0.1:0) и проверкой символов через nm -gU в CI.',
  },
  {
    index: '02',
    title: 'Многоуровневый перехват трафика без VPN entitlements',
    file: 'tweak/LCProxyHooks.m',
    details:
      'Method Swizzling NSURLSessionConfiguration (default, ephemeral, connectionProxyDictionary), перехват CFNetworkCopySystemProxySettings через встроенный fishhook (arm64 + vm_protect __DATA_CONST) и WKWebsiteDataStore.proxyConfigurations на iOS 17+. Жёсткое исключение 127.0.0.1, localhost, ::1 и прямой bypass для обновления подписок.',
  },
  {
    index: '03',
    title: 'Универсальный парсер и строгий Sanitizer JSON',
    file: 'tweak/LCConfigNormalizer.m',
    details:
      'Принимает Base64, открытый список URI, полные Xray JSON, массивы JSON-ключей и sing-box JSON. Конвертирует любой JSON в стандартный копируемый URI (LCProxyNode), а в ядро xray-rust передаёт только сгенерированный с нуля минимальный конфиг (log + local socks/http + 1 активный outbound + direct) без observatory/fakedns.',
  },
  {
    index: '04',
    title: 'Двухэтапный нативный автовыбор сервера',
    file: 'tweak/LCFastSelector.m',
    details:
      'Этап 1: параллельный TCP-префильтр на Network.framework (NWConnection, пул 16 сокетов, таймаут 800 мс) отсеивает мёртвые IP менее чем за 500 мс. Этап 2: реальный сквозной HTTP 204-тест топ-6 кандидатов через временный порт xray-rust (таймаут 2500 мс). Топ-3 узла кэшируются для failover за <100 мс.',
  },
  {
    index: '05',
    title: 'Сторожевой модуль Watchdog после сна и смены сети',
    file: 'tweak/LCWatchdog.m',
    details:
      'Отслеживает WillEnterForeground, DidBecomeActive, DidEnterBackground и NWPathMonitor (Wi-Fi <-> 5G/LTE). При пробуждении проверяет локальный порт и прохождение 204; при протухших сокетах перезапускает ядро и синхронизирует порты в хуках, либо переключается на резервный сервер из кэша. 20-секундный heartbeat приостанавливается в фоне.',
  },
  {
    index: '06',
    title: 'Автоматический CI-патчинг LiveContainer+SideStore Nightly',
    file: '.github/workflows/build.yml',
    details:
      'macOS runner скачивает XrayRust.xcframework (ios-arm64) и последний nightly LiveContainer+SideStore.ipa, компилирует LCProxyTweak.dylib под arm64-apple-ios15.0 (автоопределение static .a vs dynamic .framework через file), внедряет LC_LOAD_DYLIB через insert_dylib в основной бинарник и TweakLoader.dylib, чистит _CodeSignature и публикует готовый IPA в Releases.',
  },
];

export const ArchitectureView: React.FC<ArchitectureViewProps> = ({ onDownloadZip, onJumpToFile }) => {
  const [copiedCmd, setCopiedCmd] = useState(false);

  const handleCopyCmd = async () => {
    try {
      await navigator.clipboard.writeText(DEPLOY_COMMANDS);
      setCopiedCmd(true);
      setTimeout(() => setCopiedCmd(false), 1800);
    } catch {
      // ignore
    }
  };

  return (
    <div className="max-w-5xl mx-auto py-8 px-6 space-y-10">
      {/* Header Summary */}
      <div className="flex flex-col md:flex-row md:items-end justify-between gap-6 pb-6 border-b border-slate-200">
        <div className="max-w-2xl">
          <h1 className="text-2xl font-bold tracking-tight text-slate-900" style={{ textWrap: 'balance' }}>
            Архитектура нативного прокси-твика на базе xray-rust для LiveContainer+SideStore
          </h1>
          <p className="mt-2 text-sm text-slate-600 leading-relaxed">
            Полностью готовый к сборке репозиторий: 15 исходных файлов Objective-C / C, скрипт патчинга IPA и workflow GitHub Actions для сборки установочного пакета под бесплатный Apple ID без VPN entitlements.
          </p>
        </div>
        <button
          type="button"
          onClick={onDownloadZip}
          className="inline-flex items-center justify-center gap-2 px-4 py-2.5 text-sm font-semibold text-white bg-blue-600 rounded-lg hover:bg-blue-700 transition-colors whitespace-nowrap shrink-0 cursor-pointer"
        >
          <Download className="w-4 h-4" />
          Скачать проект (.zip)
        </button>
      </div>

      {/* Key Specs Row (Unboxed Typographic Metrics) */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-6 py-2">
        <div>
          <div className="text-xs text-slate-500">Ядро и ABI</div>
          <div className="mt-1 text-base font-semibold text-slate-900 font-mono">xray-rust · arm64</div>
          <div className="mt-0.5 text-xs text-slate-500">~5 МБ ОЗУ · старт &lt;50 мс</div>
        </div>
        <div>
          <div className="text-xs text-slate-500">Перехват в гостевых app</div>
          <div className="mt-1 text-base font-semibold text-slate-900">3 уровня хуков</div>
          <div className="mt-0.5 text-xs text-slate-500">NSURLSession · fishhook · WKWebView</div>
        </div>
        <div>
          <div className="text-xs text-slate-500">Автовыбор узла</div>
          <div className="mt-1 text-base font-semibold text-slate-900 tabular-nums">16x TCP → Top-6 204</div>
          <div className="mt-0.5 text-xs text-slate-500">Failover из кэша &lt;100 мс</div>
        </div>
        <div>
          <div className="text-xs text-slate-500">Целевой артефакт CI</div>
          <div className="mt-1 text-base font-semibold text-slate-900 font-mono truncate">LiveContainer+SideStore</div>
          <div className="mt-0.5 text-xs text-slate-500">iOS 15–26 · без VPN прав</div>
        </div>
      </div>

      {/* 6 Subsystem Breakdown */}
      <section className="space-y-4">
        <h2 className="text-base font-semibold text-slate-900">Инженерные модули проекта</h2>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {MODULES.map((m) => (
            <div
              key={m.index}
              className="p-5 bg-white border border-slate-200 rounded-lg flex flex-col justify-between gap-4"
            >
              <div>
                <div className="flex items-baseline justify-between gap-3">
                  <h3 className="text-sm font-semibold text-slate-900">
                    {m.index}. {m.title}
                  </h3>
                </div>
                <p className="mt-2 text-xs text-slate-600 leading-relaxed">{m.details}</p>
              </div>
              <div className="pt-3 border-t border-slate-100 flex items-center justify-between">
                <span className="text-xs font-mono text-slate-500">{m.file}</span>
                <button
                  type="button"
                  onClick={() => onJumpToFile(m.file)}
                  className="inline-flex items-center gap-1 text-xs font-medium text-blue-600 hover:text-blue-700 cursor-pointer whitespace-nowrap shrink-0"
                >
                  Открыть код
                  <ArrowRight className="w-3.5 h-3.5" />
                </button>
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* 4-Step GitHub Deployment Instructions */}
      <section className="p-6 bg-white border border-slate-200 rounded-lg space-y-5">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 className="text-base font-semibold text-slate-900">Как собрать готовый .ipa на GitHub за 4 шага</h2>
            <p className="mt-1 text-xs text-slate-500">
              Локальный Mac не требуется — всё компилируется автоматически на раннере macos-latest.
            </p>
          </div>
          <button
            type="button"
            onClick={handleCopyCmd}
            className="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium text-slate-700 bg-white border border-slate-200 rounded-md hover:bg-slate-50 transition-colors whitespace-nowrap shrink-0 cursor-pointer"
          >
            {copiedCmd ? <Check className="w-3.5 h-3.5 text-emerald-600" /> : <Copy className="w-3.5 h-3.5" />}
            {copiedCmd ? 'Команды скопированы' : 'Копировать git-команды'}
          </button>
        </div>

        <ol className="space-y-3 text-sm text-slate-700">
          <li className="flex gap-3">
            <span className="font-mono text-xs font-semibold text-slate-400 pt-0.5 tabular-nums">01.</span>
            <span>Нажмите <strong>Скачать .zip</strong> в правом верхнем углу и распакуйте архив в локальную папку.</span>
          </li>
          <li className="flex gap-3">
            <span className="font-mono text-xs font-semibold text-slate-400 pt-0.5 tabular-nums">02.</span>
            <span>Создайте новый репозиторий на GitHub (публичный или приватный) и отправьте файлы в ветку <code className="font-mono text-xs bg-slate-100 px-1.5 py-0.5 rounded">main</code>:</span>
          </li>
        </ol>

        <pre className="p-4 bg-[#0F172A] text-slate-100 rounded-md font-mono text-xs overflow-x-auto leading-relaxed">
          {DEPLOY_COMMANDS}
        </pre>

        <ol className="space-y-3 text-sm text-slate-700">
          <li className="flex gap-3">
            <span className="font-mono text-xs font-semibold text-slate-400 pt-0.5 tabular-nums">03.</span>
            <span>Откройте вкладку <strong>Actions</strong> — workflow <code className="font-mono text-xs bg-slate-100 px-1.5 py-0.5 rounded">Build LiveContainer+SideStore+XrayRust IPA</code> запустится автоматически (в логе шага скачивания будут выведены реальные символы <code className="font-mono text-xs bg-slate-100 px-1.5 py-0.5 rounded">nm -gU</code> и <code className="font-mono text-xs bg-slate-100 px-1.5 py-0.5 rounded">otool -L</code>).</span>
          </li>
          <li className="flex gap-3">
            <span className="font-mono text-xs font-semibold text-slate-400 pt-0.5 tabular-nums">04.</span>
            <span>Скачайте готовый <code className="font-mono text-xs bg-slate-100 px-1.5 py-0.5 rounded">LiveContainer+SideStore+XrayRust.ipa</code> из раздела <strong>Releases</strong> (или Artifacts) и установите через SideStore / Impactor / iloader.</span>
          </li>
        </ol>
      </section>
    </div>
  );
};
