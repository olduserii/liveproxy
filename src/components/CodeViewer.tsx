import React, { useState, useMemo } from 'react';
import { Check, Copy, Download, WrapText } from 'lucide-react';
import type { RepoFile, RepoFileLanguage } from '../data/repo/types';

interface CodeViewerProps {
  file: RepoFile;
}

const OBJC_C_KEYWORDS = new Set([
  'if', 'else', 'for', 'while', 'do', 'switch', 'case', 'default', 'break', 'continue', 'return',
  'typedef', 'struct', 'enum', 'union', 'static', 'extern', 'const', 'void', 'char', 'int', 'long',
  'short', 'unsigned', 'signed', 'float', 'double', 'bool', 'BOOL', 'YES', 'NO', 'NULL', 'nil',
  'sizeof', 'uint8_t', 'uint16_t', 'uint32_t', 'uint64_t', 'int64_t', 'size_t', 'ssize_t', 'intptr_t', 'uintptr_t',
  '@interface', '@implementation', '@end', '@property', '@synthesize', '@selector', '@synchronized', '@autoreleasepool', '@available',
  'NS_ENUM', 'NS_ASSUME_NONNULL_BEGIN', 'NS_ASSUME_NONNULL_END', 'nonatomic', 'strong', 'weak', 'copy', 'assign', 'readonly', 'readwrite', 'nullable', 'nonnull',
  'instancetype', 'id', 'Class', 'SEL', 'IMP', 'self', 'super', '__block', '__weak', '__strong', '__bridge', '__bridge_retained', '__bridge_transfer',
]);

const BASH_KEYWORDS = new Set([
  'if', 'then', 'else', 'elif', 'fi', 'for', 'in', 'do', 'done', 'while', 'case', 'esac', 'set', 'exit', 'echo', 'local', 'trap', 'return',
]);

function highlightLine(line: string, lang: RepoFileLanguage): React.ReactNode {
  if (!line) return '\u00A0';

  if (lang === 'objc' || lang === 'c') {
    const trimmed = line.trimStart();
    if (trimmed.startsWith('//')) {
      return <span className="text-slate-400 italic">{line}</span>;
    }
    if (trimmed.startsWith('#')) {
      return <span className="text-sky-300">{line}</span>;
    }

    const tokenRegex = /(\/\/.*$|@?"(?:\\.|[^"\\])*"|\b(?:@?[A-Za-z_][A-Za-z0-9_]*)\b|\b\d+(?:\.\d+)?\b)/g;
    const parts: React.ReactNode[] = [];
    let lastIndex = 0;
    let match: RegExpExecArray | null;
    let key = 0;

    while ((match = tokenRegex.exec(line)) !== null) {
      if (match.index > lastIndex) {
        parts.push(line.slice(lastIndex, match.index));
      }
      const token = match[0];
      if (token.startsWith('//')) {
        parts.push(<span key={key++} className="text-slate-400 italic">{token}</span>);
      } else if (token.startsWith('"') || token.startsWith('@"')) {
        parts.push(<span key={key++} className="text-emerald-300">{token}</span>);
      } else if (/^\d/.test(token)) {
        parts.push(<span key={key++} className="text-amber-300">{token}</span>);
      } else if (OBJC_C_KEYWORDS.has(token)) {
        parts.push(<span key={key++} className="text-indigo-300 font-medium">{token}</span>);
      } else if (/^(NS|UI|CF|WK|LC|CG|nw_|dispatch_)/.test(token)) {
        parts.push(<span key={key++} className="text-cyan-200">{token}</span>);
      } else {
        parts.push(token);
      }
      lastIndex = tokenRegex.lastIndex;
    }
    if (lastIndex < line.length) {
      parts.push(line.slice(lastIndex));
    }
    return parts;
  }

  if (lang === 'bash') {
    const trimmed = line.trimStart();
    if (trimmed.startsWith('#')) {
      return <span className="text-slate-400 italic">{line}</span>;
    }
    const tokenRegex = /("(?:\\.|[^"\\])*"|'(?:[^']*)'|\$\{?[A-Za-z0-9_@#?*]+\}?|\b[a-z]+\b)/g;
    const parts: React.ReactNode[] = [];
    let lastIndex = 0;
    let match: RegExpExecArray | null;
    let key = 0;
    while ((match = tokenRegex.exec(line)) !== null) {
      if (match.index > lastIndex) parts.push(line.slice(lastIndex, match.index));
      const tok = match[0];
      if (tok.startsWith('"') || tok.startsWith("'")) {
        parts.push(<span key={key++} className="text-emerald-300">{tok}</span>);
      } else if (tok.startsWith('$')) {
        parts.push(<span key={key++} className="text-amber-300">{tok}</span>);
      } else if (BASH_KEYWORDS.has(tok)) {
        parts.push(<span key={key++} className="text-indigo-300 font-medium">{tok}</span>);
      } else {
        parts.push(tok);
      }
      lastIndex = tokenRegex.lastIndex;
    }
    if (lastIndex < line.length) parts.push(line.slice(lastIndex));
    return parts;
  }

  if (lang === 'yaml') {
    const trimmed = line.trimStart();
    if (trimmed.startsWith('#')) {
      return <span className="text-slate-400 italic">{line}</span>;
    }
    const kv = line.match(/^(\s*-?\s*)([A-Za-z0-9_-]+)(:)(.*)$/);
    if (kv) {
      return (
        <>
          <span>{kv[1]}</span>
          <span className="text-sky-300">{kv[2]}</span>
          <span className="text-slate-400">{kv[3]}</span>
          <span className="text-emerald-300">{kv[4]}</span>
        </>
      );
    }
    return <span className="text-slate-200">{line}</span>;
  }

  return line;
}

export const CodeViewer: React.FC<CodeViewerProps> = ({ file }) => {
  const [copied, setCopied] = useState(false);
  const [wrap, setWrap] = useState(false);

  const lines = useMemo(() => file.content.split('\n'), [file.content]);
  const byteSize = useMemo(() => new TextEncoder().encode(file.content).length, [file.content]);

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(file.content);
      setCopied(true);
      setTimeout(() => setCopied(false), 1800);
    } catch {
      // Fallback
      const ta = document.createElement('textarea');
      ta.value = file.content;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
      document.body.removeChild(ta);
      setCopied(true);
      setTimeout(() => setCopied(false), 1800);
    }
  };

  const handleDownloadSingle = () => {
    const blob = new Blob([file.content], { type: 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = file.path.split('/').pop() || 'file.txt';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(() => URL.revokeObjectURL(url), 2000);
  };

  return (
    <div className="flex flex-col h-full min-h-0 bg-white border border-slate-200 rounded-lg overflow-hidden">
      {/* File Header Toolbar */}
      <div className="flex flex-wrap items-center justify-between gap-3 px-4 py-3 border-b border-slate-200 bg-white">
        <div className="min-w-0">
          <div className="flex items-center gap-2 text-sm font-semibold text-slate-900 font-mono truncate">
            {file.path}
          </div>
          <div className="mt-0.5 flex flex-wrap items-center gap-2 text-xs text-slate-500">
            <span className="truncate max-w-xl">{file.summary}</span>
            <span aria-hidden="true">·</span>
            <span className="font-mono tabular-nums">{lines.length} строк</span>
            <span aria-hidden="true">·</span>
            <span className="font-mono tabular-nums">{(byteSize / 1024).toFixed(1)} КБ</span>
            {file.executable && (
              <>
                <span aria-hidden="true">·</span>
                <span className="font-mono text-slate-600">chmod +x (0755)</span>
              </>
            )}
          </div>
        </div>

        <div className="flex items-center gap-2 shrink-0">
          <button
            type="button"
            onClick={() => setWrap((w) => !w)}
            title="Перенос длинных строк"
            className={`inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-md border transition-colors whitespace-nowrap shrink-0 cursor-pointer ${
              wrap
                ? 'bg-slate-900 text-white border-slate-900'
                : 'bg-white text-slate-700 border-slate-200 hover:bg-slate-50'
            }`}
          >
            <WrapText className="w-3.5 h-3.5" />
            Перенос
          </button>

          <button
            type="button"
            onClick={handleCopy}
            className="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium text-slate-700 bg-white border border-slate-200 rounded-md hover:bg-slate-50 transition-colors whitespace-nowrap shrink-0 cursor-pointer"
          >
            {copied ? <Check className="w-3.5 h-3.5 text-emerald-600" /> : <Copy className="w-3.5 h-3.5" />}
            {copied ? 'Скопировано' : 'Копировать'}
          </button>

          <button
            type="button"
            onClick={handleDownloadSingle}
            className="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium text-slate-700 bg-white border border-slate-200 rounded-md hover:bg-slate-50 transition-colors whitespace-nowrap shrink-0 cursor-pointer"
          >
            <Download className="w-3.5 h-3.5" />
            Файл
          </button>
        </div>
      </div>

      {/* High-Contrast Monospace Code Surface */}
      <div className="flex-1 min-h-0 overflow-auto bg-[#0F172A] text-slate-100">
        <table className="w-full border-collapse font-mono text-[12.5px] leading-[1.6]">
          <tbody>
            {lines.map((line, idx) => (
              <tr key={idx} className="hover:bg-slate-800/50">
                <td className="select-none text-right align-top pr-4 pl-4 py-0 text-slate-500 border-r border-slate-800/80 w-12 tabular-nums">
                  {idx + 1}
                </td>
                <td className={`pl-4 pr-6 py-0 align-top ${wrap ? 'whitespace-pre-wrap break-all' : 'whitespace-pre'}`}>
                  {highlightLine(line, file.language)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
};
