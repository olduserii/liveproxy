import JSZip from 'jszip';
import type { RepoFile } from './types';

import fishhookH from '../../../tweak/fishhook.h?raw';
import fishhookC from '../../../tweak/fishhook.c?raw';
import bridgeH from '../../../tweak/LCXrayRustBridge.h?raw';
import bridgeM from '../../../tweak/LCXrayRustBridge.m?raw';
import proxyNodeH from '../../../tweak/LCProxyNode.h?raw';
import proxyNodeM from '../../../tweak/LCProxyNode.m?raw';
import normalizerH from '../../../tweak/LCConfigNormalizer.h?raw';
import normalizerM from '../../../tweak/LCConfigNormalizer.m?raw';
import selectorH from '../../../tweak/LCFastSelector.h?raw';
import selectorM from '../../../tweak/LCFastSelector.m?raw';
import watchdogH from '../../../tweak/LCWatchdog.h?raw';
import watchdogM from '../../../tweak/LCWatchdog.m?raw';
import managerH from '../../../tweak/LCProxyManager.h?raw';
import managerM from '../../../tweak/LCProxyManager.m?raw';
import hooksH from '../../../tweak/LCProxyHooks.h?raw';
import hooksM from '../../../tweak/LCProxyHooks.m?raw';
import uiH from '../../../tweak/LCProxyUI.h?raw';
import uiM from '../../../tweak/LCProxyUI.m?raw';
import tweakEntryM from '../../../tweak/TweakEntry.m?raw';
import patchIpaSh from '../../../scripts/patch_ipa.sh?raw';
import buildYml from '../../../.github/workflows/build.yml?raw';
import readmeMd from '../../../README.md?raw';

export type { RepoFile, RepoFileLanguage } from './types';

export const BASE_REPO_FILES: RepoFile[] = [
  {
    path: 'tweak/fishhook.h',
    language: 'c',
    category: 'tweak',
    summary: 'Заголовок встроенного fishhook для ребиндинга C-символов Mach-O',
    content: fishhookH,
  },
  {
    path: 'tweak/fishhook.c',
    language: 'c',
    category: 'tweak',
    summary: 'Встроенная реализация fishhook (с vm_protect для __DATA_CONST на iOS 15–26)',
    content: fishhookC,
  },
  {
    path: 'tweak/LCXrayRustBridge.h',
    language: 'objc',
    category: 'tweak',
    summary: 'Изолированный Objective-C адаптер над C ABI aimalygin/xray-rust-mobile (xray_ffi.h)',
    content: bridgeH,
  },
  {
    path: 'tweak/LCXrayRustBridge.m',
    language: 'objc',
    category: 'tweak',
    summary: 'Прямая привязка к xray_core_new/load_config_json/start/stop/free + rebind carrier sockets',
    content: bridgeM,
  },
  {
    path: 'tweak/LCProxyNode.h',
    language: 'objc',
    category: 'tweak',
    summary: 'Единая модель прокси-узла (VLESS/REALITY/XHTTP, HY2, Trojan, VMess, SS-2022, WG, SOCKS5, HTTP)',
    content: proxyNodeH,
  },
  {
    path: 'tweak/LCProxyNode.m',
    language: 'objc',
    category: 'tweak',
    summary: 'Реализация LCProxyNode: сериализация в JSON и обратная генерация стандартного URI-ключа',
    content: proxyNodeM,
  },
  {
    path: 'tweak/LCConfigNormalizer.h',
    language: 'objc',
    category: 'tweak',
    summary: 'Заголовок универсального нормализатора подписок, ключей, Xray/sing-box JSON и строгого генератора JSON',
    content: normalizerH,
  },
  {
    path: 'tweak/LCConfigNormalizer.m',
    language: 'objc',
    category: 'tweak',
    summary: 'Парсер URI/Base64/Xray/sing-box + загрузка подписок + строгий минимальный JSON под xray-rust',
    content: normalizerM,
  },
  {
    path: 'tweak/LCFastSelector.h',
    language: 'objc',
    category: 'tweak',
    summary: 'Заголовок двухэтапного быстрого автовыбора (TCP-префильтр + реальный 204-тест через xray-rust)',
    content: selectorH,
  },
  {
    path: 'tweak/LCFastSelector.m',
    language: 'objc',
    category: 'tweak',
    summary: '16x параллельный NWConnection TCP-префильтр (800ms) + топ-6 реальных 204-замеров через xray-rust',
    content: selectorM,
  },
  {
    path: 'tweak/LCWatchdog.h',
    language: 'objc',
    category: 'tweak',
    summary: 'Заголовок сторожа живучести после сна iOS, переключения Wi-Fi <-> 5G и 20s heartbeat',
    content: watchdogH,
  },
  {
    path: 'tweak/LCWatchdog.m',
    language: 'objc',
    category: 'tweak',
    summary: 'Реализация verifyAndReviveProxy + NWPathMonitor + carrier socket rebind + <100ms failover',
    content: watchdogM,
  },
  {
    path: 'tweak/LCProxyManager.h',
    language: 'objc',
    category: 'tweak',
    summary: 'Заголовок центрального менеджера состояния, подписок, кэша бэкапов и кольцевого лога',
    content: managerH,
  },
  {
    path: 'tweak/LCProxyManager.m',
    language: 'objc',
    category: 'tweak',
    summary: 'Общее хранилище Application Support/LCProxy/, управление ядром, автообновление подписок и failover',
    content: managerM,
  },
  {
    path: 'tweak/LCProxyHooks.h',
    language: 'objc',
    category: 'tweak',
    summary: 'Заголовок многоуровневого перехвата (NSURLSession, fishhook CFNetwork, WKWebView iOS 17+)',
    content: hooksH,
  },
  {
    path: 'tweak/LCProxyHooks.m',
    language: 'objc',
    category: 'tweak',
    summary: 'Swizzling NSURLSessionConfiguration + fishhook CFNetworkCopySystemProxySettings + WKWebsiteDataStore',
    content: hooksM,
  },
  {
    path: 'tweak/LCProxyUI.h',
    language: 'objc',
    category: 'tweak',
    summary: 'Заголовок плавающей UIKit-кнопки (XR), жеста 3 пальца × 3 тапа и панели управления',
    content: uiH,
  },
  {
    path: 'tweak/LCProxyUI.m',
    language: 'objc',
    category: 'tweak',
    summary: 'Компактный UI на чистом UIKit (iOS 15–26): статус, серверы, подписки, логи и плавающая кнопка',
    content: uiM,
  },
  {
    path: 'tweak/TweakEntry.m',
    language: 'objc',
    category: 'tweak',
    summary: 'Точка входа __attribute__((constructor)) — инициализация хуков, ядра, watchdog и UI при загрузке dylib',
    content: tweakEntryM,
  },
  {
    path: 'scripts/patch_ipa.sh',
    language: 'bash',
    category: 'ci',
    executable: true,
    summary: 'Скрипт патчинга LiveContainer+SideStore.ipa: копирование dylib, инъекция в бинарник и TweakLoader',
    content: patchIpaSh,
  },
  {
    path: '.github/workflows/build.yml',
    language: 'yaml',
    category: 'ci',
    summary: 'GitHub Actions macOS workflow: загрузка XrayRust + сборка LCProxyTweak.dylib + патчинг IPA + Release',
    content: buildYml,
  },
  {
    path: 'README.md',
    language: 'markdown',
    category: 'docs',
    summary: 'Полная инструкция по сборке в GitHub Actions, установке через SideStore и использованию',
    content: readmeMd,
  },
];

export function getRepoFiles(customABIHeader?: string): RepoFile[] {
  const trimmed = customABIHeader?.trim();
  if (!trimmed) {
    return BASE_REPO_FILES;
  }
  const customFile: RepoFile = {
    path: 'tweak/LCXrayRustCustomABI.h',
    language: 'c',
    category: 'tweak',
    summary: 'Пользовательский .h заголовок C ABI из aimalygin/xray-rust-mobile (подключается автоматически в LCXrayRustBridge.m)',
    content: trimmed + '\n',
  };
  const bridgeIdx = BASE_REPO_FILES.findIndex((f) => f.path === 'tweak/LCXrayRustBridge.h');
  const next = [...BASE_REPO_FILES];
  next.splice(bridgeIdx >= 0 ? bridgeIdx : 0, 0, customFile);
  return next;
}

export function getRepoStats(files: RepoFile[]) {
  let totalLines = 0;
  let totalBytes = 0;
  for (const f of files) {
    totalLines += f.content.split('\n').length;
    totalBytes += new TextEncoder().encode(f.content).length;
  }
  return {
    fileCount: files.length,
    totalLines,
    totalBytes,
  };
}

export async function downloadRepoZip(files: RepoFile[], archiveName = 'livecontainer-sidestore-xray-rust.zip'): Promise<void> {
  const zip = new JSZip();
  for (const file of files) {
    zip.file(file.path, file.content, {
      unixPermissions: file.executable ? '755' : '644',
    });
  }
  const blob = await zip.generateAsync({
    type: 'blob',
    platform: 'UNIX',
    compression: 'DEFLATE',
    compressionOptions: { level: 9 },
  });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = archiveName;
  document.body.appendChild(anchor);
  anchor.click();
  document.body.removeChild(anchor);
  setTimeout(() => URL.revokeObjectURL(url), 4000);
}
