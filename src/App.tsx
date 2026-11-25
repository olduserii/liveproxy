import React, { useMemo, useState } from 'react';
import {
  ChevronDown,
  ChevronRight,
  Download,
  FileCode2,
  Folder,
  FolderOpen,
  Search,
  SlidersHorizontal,
  X,
} from 'lucide-react';
import { downloadRepoZip, getRepoFiles, getRepoStats, type RepoFile } from './data/repo';
import { CodeViewer } from './components/CodeViewer';
import { ArchitectureView } from './components/ArchitectureView';
import { NormalizerSandbox } from './components/NormalizerSandbox';

type ActiveTab = 'code' | 'architecture' | 'sandbox';

interface FolderGroup {
  dir: string;
  label: string;
  files: RepoFile[];
}

export default function App() {
  const [activeTab, setActiveTab] = useState<ActiveTab>('code');
  const [customABIHeader, setCustomABIHeader] = useState('');
  const [showABIPanel, setShowABIPanel] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');
  const [downloading, setDownloading] = useState(false);
  const [collapsedDirs, setCollapsedDirs] = useState<Record<string, boolean>>({});

  const allFiles = useMemo(() => getRepoFiles(customABIHeader), [customABIHeader]);
  const stats = useMemo(() => getRepoStats(allFiles), [allFiles]);

  const [selectedPath, setSelectedPath] = useState<string>('tweak/LCXrayRustBridge.m');

  const filteredFiles = useMemo(() => {
    const q = searchQuery.trim().toLowerCase();
    if (!q) return allFiles;
    return allFiles.filter(
      (f) =>
        f.path.toLowerCase().includes(q) ||
        f.summary.toLowerCase().includes(q) ||
        f.content.toLowerCase().includes(q),
    );
  }, [allFiles, searchQuery]);

  const folderGroups = useMemo<FolderGroup[]>(() => {
    const order = ['.github/workflows', 'scripts', 'tweak', ''];
    const map = new Map<string, RepoFile[]>();
    for (const f of filteredFiles) {
      const idx = f.path.lastIndexOf('/');
      const dir = idx >= 0 ? f.path.slice(0, idx) : '';
      if (!map.has(dir)) map.set(dir, []);
      map.get(dir)!.push(f);
    }
    const groups: FolderGroup[] = [];
    for (const dir of order) {
      const list = map.get(dir);
      if (list && list.length > 0) {
        groups.push({
          dir,
          label: dir || 'Корень репозитория',
          files: list,
        });
      }
    }
    return groups;
  }, [filteredFiles]);

  const selectedFile = useMemo(() => {
    return allFiles.find((f) => f.path === selectedPath) || allFiles[0];
  }, [allFiles, selectedPath]);

  const handleDownloadZip = async () => {
    setDownloading(true);
    try {
      await downloadRepoZip(allFiles, 'livecontainer-sidestore-xray-rust.zip');
    } finally {
      setTimeout(() => setDownloading(false), 450);
    }
  };

  const handleJumpToFile = (path: string) => {
    setSelectedPath(path);
    setActiveTab('code');
  };

  const toggleDir = (dir: string) => {
    setCollapsedDirs((prev) => ({ ...prev, [dir]: !prev[dir] }));
  };

  return (
    <div className="min-h-screen h-screen flex flex-col bg-slate-50 text-slate-900 overflow-hidden">
      {/* Strict 3-Zone Top Bar Contract */}
      <header className="h-14 shrink-0 bg-white border-b border-slate-200 px-6 flex items-center justify-between gap-8">
        {/* Zone 1: Single-element Brand Wordmark */}
        <button
          type="button"
          onClick={() => setActiveTab('code')}
          className="text-base font-bold tracking-tight text-slate-900 whitespace-nowrap shrink-0 cursor-pointer"
        >
          LCProxy XrayRust
        </button>

        {/* Zone 2: Clean Single-Line Navigation Links */}
        <nav className="flex items-center gap-6 h-full overflow-x-auto" aria-label="Основная навигация">
          <button
            type="button"
            onClick={() => setActiveTab('code')}
            className={`h-full inline-flex items-center text-sm font-medium border-b-2 transition-colors whitespace-nowrap shrink-0 cursor-pointer ${
              activeTab === 'code'
                ? 'border-blue-600 text-slate-900'
                : 'border-transparent text-slate-600 hover:text-slate-900'
            }`}
          >
            Исходный код
          </button>
          <button
            type="button"
            onClick={() => setActiveTab('architecture')}
            className={`h-full inline-flex items-center text-sm font-medium border-b-2 transition-colors whitespace-nowrap shrink-0 cursor-pointer ${
              activeTab === 'architecture'
                ? 'border-blue-600 text-slate-900'
                : 'border-transparent text-slate-600 hover:text-slate-900'
            }`}
          >
            Архитектура и CI
          </button>
          <button
            type="button"
            onClick={() => setActiveTab('sandbox')}
            className={`h-full inline-flex items-center text-sm font-medium border-b-2 transition-colors whitespace-nowrap shrink-0 cursor-pointer ${
              activeTab === 'sandbox'
                ? 'border-blue-600 text-slate-900'
                : 'border-transparent text-slate-600 hover:text-slate-900'
            }`}
          >
            Тест нормализатора
          </button>
        </nav>

        {/* Zone 3: 1 Primary Action */}
        <div className="flex items-center shrink-0">
          <button
            type="button"
            onClick={handleDownloadZip}
            disabled={downloading}
            className="inline-flex items-center gap-2 px-4 py-2 text-xs font-semibold text-white bg-blue-600 rounded-lg hover:bg-blue-700 disabled:opacity-60 transition-colors whitespace-nowrap shrink-0 cursor-pointer"
          >
            <Download className="w-3.5 h-3.5" />
            {downloading ? 'Сборка .zip...' : 'Скачать .zip'}
          </button>
        </div>
      </header>

      {/* Main Content Viewport */}
      <main className="flex-1 min-h-0 overflow-hidden">
        {activeTab === 'code' && (
          <div className="h-full flex min-h-0">
            {/* Left Sidebar: Repository File Explorer */}
            <aside className="w-72 shrink-0 bg-white border-r border-slate-200 flex flex-col min-h-0">
              {/* Repo Stats & Search */}
              <div className="p-4 border-b border-slate-200 space-y-3">
                <div className="flex items-center justify-between text-xs text-slate-500">
                  <span className="font-mono tabular-nums">{stats.fileCount} файлов</span>
                  <span aria-hidden="true">·</span>
                  <span className="font-mono tabular-nums">{stats.totalLines.toLocaleString('ru-RU')} строк</span>
                  <span aria-hidden="true">·</span>
                  <span className="font-mono tabular-nums">{(stats.totalBytes / 1024).toFixed(0)} КБ</span>
                </div>

                <div className="relative">
                  <Search className="w-3.5 h-3.5 text-slate-400 absolute left-3 top-1/2 -translate-y-1/2 pointer-events-none" />
                  <input
                    type="text"
                    value={searchQuery}
                    onChange={(e) => setSearchQuery(e.target.value)}
                    placeholder="Поиск по файлам и коду..."
                    className="w-full pl-8 pr-7 py-1.5 text-xs bg-slate-50 border border-slate-200 rounded-md text-slate-900 placeholder:text-slate-400 focus:outline-none focus:border-blue-500 focus:bg-white transition-colors"
                  />
                  {searchQuery && (
                    <button
                      type="button"
                      onClick={() => setSearchQuery('')}
                      aria-label="Сбросить поиск"
                      className="absolute right-2 top-1/2 -translate-y-1/2 text-slate-400 hover:text-slate-600 cursor-pointer"
                    >
                      <X className="w-3.5 h-3.5" />
                    </button>
                  )}
                </div>
              </div>

              {/* File Tree */}
              <div className="flex-1 min-h-0 overflow-y-auto py-2 px-2 space-y-1">
                {folderGroups.length === 0 ? (
                  <div className="px-3 py-6 text-center text-xs text-slate-500">
                    Ничего не найдено по запросу «{searchQuery}»
                  </div>
                ) : (
                  folderGroups.map((group) => {
                    const isCollapsed = Boolean(collapsedDirs[group.dir]);
                    return (
                      <div key={group.dir || '__root__'} className="space-y-0.5">
                        <button
                          type="button"
                          onClick={() => toggleDir(group.dir)}
                          className="w-full flex items-center gap-1.5 px-2 py-1.5 text-xs font-semibold text-slate-600 hover:text-slate-900 rounded-md hover:bg-slate-50 transition-colors cursor-pointer"
                        >
                          {isCollapsed ? (
                            <ChevronRight className="w-3.5 h-3.5 text-slate-400 shrink-0" />
                          ) : (
                            <ChevronDown className="w-3.5 h-3.5 text-slate-400 shrink-0" />
                          )}
                          {isCollapsed ? (
                            <Folder className="w-3.5 h-3.5 text-slate-400 shrink-0" />
                          ) : (
                            <FolderOpen className="w-3.5 h-3.5 text-slate-500 shrink-0" />
                          )}
                          <span className="truncate font-mono">{group.label}</span>
                        </button>

                        {!isCollapsed && (
                          <div className="pl-3 space-y-0.5">
                            {group.files.map((file) => {
                              const fileName = file.path.includes('/')
                                ? file.path.slice(file.path.lastIndexOf('/') + 1)
                                : file.path;
                              const isSelected = selectedFile?.path === file.path;
                              return (
                                <button
                                  key={file.path}
                                  type="button"
                                  onClick={() => setSelectedPath(file.path)}
                                  className={`w-full flex items-center gap-2 px-2.5 py-1.5 text-left text-xs font-mono rounded-md transition-colors cursor-pointer ${
                                    isSelected
                                      ? 'bg-blue-50 text-blue-700 font-medium'
                                      : 'text-slate-700 hover:bg-slate-100 hover:text-slate-900'
                                  }`}
                                >
                                  <FileCode2
                                    className={`w-3.5 h-3.5 shrink-0 ${
                                      isSelected ? 'text-blue-600' : 'text-slate-400'
                                    }`}
                                  />
                                  <span className="truncate">{fileName}</span>
                                </button>
                              );
                            })}
                          </div>
                        )}
                      </div>
                    );
                  })
                )}
              </div>

              {/* Optional Custom XrayRust C ABI Header Injection */}
              <div className="p-3 border-t border-slate-200 bg-slate-50/70">
                <button
                  type="button"
                  onClick={() => setShowABIPanel((v) => !v)}
                  className="w-full flex items-center justify-between gap-2 px-2.5 py-2 text-xs font-medium text-slate-700 bg-white border border-slate-200 rounded-md hover:bg-slate-50 transition-colors cursor-pointer"
                >
                  <span className="inline-flex items-center gap-1.5 truncate">
                    <SlidersHorizontal className="w-3.5 h-3.5 text-slate-500 shrink-0" />
                    <span className="truncate">Свой .h из xray-rust-mobile</span>
                  </span>
                  <span className="text-[11px] font-mono text-slate-400 shrink-0">
                    {customABIHeader.trim() ? 'Задан' : 'Опц.'}
                  </span>
                </button>
              </div>
            </aside>

            {/* Right Main Code Panel */}
            <section className="flex-1 min-w-0 min-h-0 flex flex-col p-4 gap-4 overflow-hidden">
              {showABIPanel && (
                <div className="shrink-0 p-4 bg-white border border-slate-200 rounded-lg space-y-2.5">
                  <div className="flex items-center justify-between gap-3">
                    <div>
                      <h2 className="text-xs font-semibold text-slate-900">
                        Опционально: вставьте текст .h файла из aimalygin/xray-rust-mobile
                      </h2>
                      <p className="text-xs text-slate-500">
                        Будет автоматически добавлен как <code className="font-mono">tweak/LCXrayRustCustomABI.h</code> в архив .zip и подключён в <code className="font-mono">LCXrayRustBridge.m</code>.
                      </p>
                    </div>
                    <button
                      type="button"
                      onClick={() => setShowABIPanel(false)}
                      className="text-slate-400 hover:text-slate-700 cursor-pointer"
                      aria-label="Закрыть панель C ABI"
                    >
                      <X className="w-4 h-4" />
                    </button>
                  </div>
                  <textarea
                    value={customABIHeader}
                    onChange={(e) => setCustomABIHeader(e.target.value)}
                    rows={5}
                    spellCheck={false}
                    placeholder="// Например: int xray_rust_start(const char *config_json); ..."
                    className="w-full p-2.5 font-mono text-xs bg-slate-50 border border-slate-200 rounded-md text-slate-900 focus:outline-none focus:border-blue-500"
                  />
                </div>
              )}

              <div className="flex-1 min-h-0">
                {selectedFile && <CodeViewer file={selectedFile} />}
              </div>
            </section>
          </div>
        )}

        {activeTab === 'architecture' && (
          <div className="h-full overflow-y-auto">
            <ArchitectureView onDownloadZip={handleDownloadZip} onJumpToFile={handleJumpToFile} />
          </div>
        )}

        {activeTab === 'sandbox' && (
          <div className="h-full overflow-y-auto">
            <NormalizerSandbox />
          </div>
        )}
      </main>
    </div>
  );
}
