export type RepoFileLanguage = 'objc' | 'c' | 'bash' | 'yaml' | 'markdown' | 'text';

export interface RepoFile {
  path: string;
  language: RepoFileLanguage;
  category: 'tweak' | 'ci' | 'scripts' | 'docs';
  summary: string;
  executable?: boolean;
  content: string;
}
