import JSZip from 'jszip';
import type { RepoFile } from './types';
import { fishhookFiles } from './fishhookFiles';
import { bridgeAndNodeFiles } from './bridgeAndNodeFiles';
import { normalizerFiles } from './normalizerFiles';
import { selectorAndWatchdogFiles } from './selectorAndWatchdogFiles';
import { managerAndHooksFiles } from './managerAndHooksFiles';
import { uiAndEntryFiles } from './uiAndEntryFiles';
import { ciAndDocsFiles } from './ciAndDocsFiles';

export type { RepoFile, RepoFileLanguage } from './types';

export const BASE_REPO_FILES: RepoFile[] = [
  ...fishhookFiles,
  ...bridgeAndNodeFiles,
  ...normalizerFiles,
  ...selectorAndWatchdogFiles,
  ...managerAndHooksFiles,
  ...uiAndEntryFiles,
  ...ciAndDocsFiles,
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
