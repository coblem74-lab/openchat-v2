// The public npm localtunnel endpoint is the default for web builds and desktop.
export const DEFAULT_API_BASE = 'https://openchat-mrtristin.loca.lt';
const STORAGE_KEY = 'openchat_server';

export function getApiBase(): string {
  try {
    return (localStorage.getItem(STORAGE_KEY) || DEFAULT_API_BASE).trim().replace(/\/+$/, '');
  } catch {
    return DEFAULT_API_BASE;
  }
}

export function setApiBase(url: string) {
  const trimmed = (url || '').trim().replace(/\/+$/, '');
  if (!trimmed) localStorage.removeItem(STORAGE_KEY);
  else localStorage.setItem(STORAGE_KEY, trimmed);
}

export function apiUrl(path: string): string {
  return getApiBase() + path;
}

/** True when running inside the Electron shell (desktop app). */
export function isDesktop(): boolean {
  return (
    typeof window !== 'undefined' &&
    (new URLSearchParams(window.location.search).get('desktop') === '1' ||
      !!(window as any).__OPENCHAT_DESKTOP__)
  );
}

async function probeUrl(url: string): Promise<boolean> {
  if (!url) return false;
  try {
    const controller = new AbortController();
    const t = setTimeout(() => controller.abort(), 1500);
    const res = await fetch(url.replace(/\/+$/, '') + '/api/health', {
      signal: controller.signal,
      cache: 'no-store',
    });
    clearTimeout(t);
    return res.ok;
  } catch {
    return false;
  }
}

/** Resolve a saved/desktop override, otherwise use the npm tunnel endpoint. */
export async function resolveServerUrl(): Promise<string> {
  const stored = getApiBase();

  if (stored && (await probeUrl(stored))) {
    setApiBase(stored);
    return stored;
  }

  if (isDesktop()) {
    const params = new URLSearchParams(window.location.search);
    const server = (params.get('server') || '').trim().replace(/\/+$/, '');
    if (server && server !== stored && (await probeUrl(server))) {
      setApiBase(server);
      return server;
    }
  }

  setApiBase(DEFAULT_API_BASE);
  return DEFAULT_API_BASE;
}
