import { ui, defaultLang } from './ui';

export type Lang = keyof typeof ui;

export type UiKey = keyof (typeof ui)[typeof defaultLang];

export function useTranslations(lang: Lang) {
  return function t(key: UiKey | (string & {})): string {
    const dict = ui[lang] as Record<string, string>;
    const fallback = ui[defaultLang] as Record<string, string>;
    return dict[key] ?? fallback[key] ?? key;
  };
}

/** Path of the same page in the other language (used by the lang switcher + hreflang). */
export function localizePath(lang: Lang, path = '/'): string {
  return lang === defaultLang ? path : `/${lang}${path}`;
}
