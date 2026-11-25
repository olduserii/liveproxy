import React, { useState, useMemo } from 'react';
import { Check, Copy } from 'lucide-react';
import { runNormalizerSandbox } from '../utils/normalizerSandbox';

const SAMPLE_DIRTY_XRAY_JSON = `{
  "remarks": "DE-Frankfurt-XHTTP-Reality",
  "log": { "loglevel": "debug" },
  "observatory": { "subjectSelector": ["proxy"], "probeInterval": "1m" },
  "burstObservatory": { "subjectSelector": ["proxy"] },
  "fakedns": [{ "ipPool": "198.18.0.0/15", "poolSize": 65535 }],
  "stats": {},
  "policy": { "levels": { "0": { "statsUserUplink": true } } },
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "mux": { "enabled": true, "concurrency": 8 },
      "settings": {
        "vnext": [{
          "address": "185.199.110.42",
          "port": 443,
          "users": [{
            "id": "8f2a9c10-4b1a-4e8d-9b7a-1c3e5f7a9b2d",
            "encryption": "none"
          }]
        }]
      },
      "streamSettings": {
        "network": "splithttp",
        "security": "reality",
        "realitySettings": {
          "serverName": "www.microsoft.com",
          "fingerprint": "chrome",
          "publicKey": "mQ7vR8xY2zK9pL4wN6jH1tG5bF3dS0aC8eU2iO7qW1k",
          "shortId": "a1b2c3d4",
          "spiderX": "/"
        },
        "splithttpSettings": {
          "path": "/xhttp-edge",
          "host": "cdn.example.net",
          "mode": "packet-up"
        }
      }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ]
}`;

const SAMPLE_SINGBOX_HY2 = `{
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "NL-Amsterdam-HY2",
      "server": "91.108.56.130",
      "server_port": 8443,
      "password": "super-secret-hy2-password",
      "obfs": {
        "type": "salamander",
        "password": "obfs-key-991"
      },
      "tls": {
        "enabled": true,
        "server_name": "cdn.cloudflare.net",
        "insecure": false
      }
    },
    { "type": "direct", "tag": "direct" }
  ]
}`;

const SAMPLE_VLESS_VISION_URI =
  'vless://a3b4c5d6-1122-4455-8899-aabbccddeeff@fi.edge-node.example:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=safari&pbk=k9L2mN5pQ8rS1tU4vW7xY0zA3bC6dE9fG2hI5jK8lM1&sid=01ef&type=tcp#FI-Helsinki-Vision';

export const NormalizerSandbox: React.FC = () => {
  const [rawInput, setRawInput] = useState(SAMPLE_DIRTY_XRAY_JSON);
  const [copiedId, setCopiedId] = useState<string | null>(null);

  const output = useMemo(() => runNormalizerSandbox(rawInput), [rawInput]);

  const copyText = async (id: string, text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopiedId(id);
      setTimeout(() => setCopiedId(null), 1600);
    } catch {
      // ignore
    }
  };

  return (
    <div className="max-w-6xl mx-auto py-8 px-6 space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-4 pb-5 border-b border-slate-200">
        <div>
          <h1 className="text-xl font-bold tracking-tight text-slate-900">
            Проверка конвейера LCConfigNormalizer
          </h1>
          <p className="mt-1 text-sm text-slate-600">
            Вставьте «грязный» Xray JSON, sing-box JSON, Base64-подписку или URI-ссылку, чтобы увидеть автоматическую конвертацию JSON → стандартный URI и генерацию строгого минимального JSON для xray-rust.
          </p>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <button
            type="button"
            onClick={() => setRawInput(SAMPLE_DIRTY_XRAY_JSON)}
            className="px-3 py-1.5 text-xs font-medium text-slate-700 bg-white border border-slate-200 rounded-md hover:bg-slate-50 transition-colors whitespace-nowrap shrink-0 cursor-pointer"
          >
            Пример: Xray JSON (XHTTP)
          </button>
          <button
            type="button"
            onClick={() => setRawInput(SAMPLE_SINGBOX_HY2)}
            className="px-3 py-1.5 text-xs font-medium text-slate-700 bg-white border border-slate-200 rounded-md hover:bg-slate-50 transition-colors whitespace-nowrap shrink-0 cursor-pointer"
          >
            Пример: sing-box (HY2)
          </button>
          <button
            type="button"
            onClick={() => setRawInput(SAMPLE_VLESS_VISION_URI)}
            className="px-3 py-1.5 text-xs font-medium text-slate-700 bg-white border border-slate-200 rounded-md hover:bg-slate-50 transition-colors whitespace-nowrap shrink-0 cursor-pointer"
          >
            Пример: VLESS Vision URI
          </button>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6 items-start">
        {/* Left: Raw Input */}
        <div className="bg-white border border-slate-200 rounded-lg overflow-hidden flex flex-col">
          <div className="px-4 py-3 border-b border-slate-200 flex items-center justify-between">
            <span className="text-xs font-semibold text-slate-800">
              Шаг 1. Сырой ввод (URI / Base64 / Xray JSON / sing-box JSON)
            </span>
            <button
              type="button"
              onClick={() => setRawInput('')}
              className="text-xs text-slate-500 hover:text-slate-900 cursor-pointer"
            >
              Очистить
            </button>
          </div>
          <textarea
            value={rawInput}
            onChange={(e) => setRawInput(e.target.value)}
            spellCheck={false}
            rows={22}
            placeholder="Вставьте vless://, hysteria2://, trojan://, ss://, Base64 или JSON-конфиг..."
            className="w-full p-4 font-mono text-xs leading-relaxed bg-[#0F172A] text-slate-100 focus:outline-none resize-y"
          />
        </div>

        {/* Right: Normalized Outputs */}
        <div className="space-y-4">
          {output.error ? (
            <div className="p-5 bg-white border border-red-200 rounded-lg text-sm text-red-700">
              {output.error}
            </div>
          ) : (
            output.results.map((item, idx) => (
              <div key={idx} className="bg-white border border-slate-200 rounded-lg overflow-hidden">
                <div className="px-4 py-3 border-b border-slate-200 flex flex-wrap items-center justify-between gap-2">
                  <div>
                    <div className="text-sm font-semibold text-slate-900">{item.node.name}</div>
                    <div className="mt-0.5 text-xs text-slate-500 font-mono">
                      {item.badge} · {item.node.host}:{item.node.port}
                    </div>
                  </div>
                  {item.strippedFields.length > 0 && (
                    <div className="text-xs text-amber-700 font-mono">
                      Удалены лишние поля: {item.strippedFields.join(', ')}
                    </div>
                  )}
                </div>

                {/* Step 2: Converted Standard URI */}
                <div className="p-4 border-b border-slate-200 space-y-2">
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-xs font-semibold text-slate-700">
                      Шаг 2. Конвертированный чистый URI-ключ
                    </span>
                    <button
                      type="button"
                      onClick={() => copyText(`uri-${idx}`, item.standardURI)}
                      className="inline-flex items-center gap-1 text-xs font-medium text-blue-600 hover:text-blue-700 cursor-pointer whitespace-nowrap shrink-0"
                    >
                      {copiedId === `uri-${idx}` ? <Check className="w-3.5 h-3.5 text-emerald-600" /> : <Copy className="w-3.5 h-3.5" />}
                      {copiedId === `uri-${idx}` ? 'Скопировано' : 'Копировать URI'}
                    </button>
                  </div>
                  <div className="p-3 bg-slate-50 border border-slate-200 rounded-md font-mono text-[11.5px] text-slate-800 break-all select-all">
                    {item.standardURI}
                  </div>
                </div>

                {/* Step 3: Strict Minimal xray-rust JSON */}
                <div className="p-4 space-y-2">
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-xs font-semibold text-slate-700">
                      Шаг 3. Строгий минимальный JSON для ядра xray-rust
                    </span>
                    <button
                      type="button"
                      onClick={() => copyText(`json-${idx}`, item.strictXrayJSON)}
                      className="inline-flex items-center gap-1 text-xs font-medium text-blue-600 hover:text-blue-700 cursor-pointer whitespace-nowrap shrink-0"
                    >
                      {copiedId === `json-${idx}` ? <Check className="w-3.5 h-3.5 text-emerald-600" /> : <Copy className="w-3.5 h-3.5" />}
                      {copiedId === `json-${idx}` ? 'Скопировано' : 'Копировать JSON'}
                    </button>
                  </div>
                  <pre className="p-3.5 bg-[#0F172A] text-emerald-300 rounded-md font-mono text-[11.5px] leading-relaxed overflow-x-auto max-h-80">
                    {item.strictXrayJSON}
                  </pre>
                </div>
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
};
