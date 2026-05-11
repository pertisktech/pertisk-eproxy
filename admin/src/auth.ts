const TOKEN_KEY = 'pertisk_token';
const USERNAME_KEY = 'pertisk_username';
const EMAIL_KEY = 'pertisk_email';
const PICTURE_KEY = 'pertisk_picture';
const AUTH_METHOD_KEY = 'pertisk_auth_method';

export type AuthMethod = 'local' | 'sso';

/** Session cookie max-age: 60 minutes (seconds). */
const SESSION_MAX_AGE_SECS = 60 * 60;
export const DEFAULT_SESSION_TTL_SECS = SESSION_MAX_AGE_SECS;

function getCookie(name: string): string | null {
  const match = document.cookie.match(
    new RegExp('(?:^|;\\s*)' + name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '=([^;]*)')
  );
  return match ? decodeURIComponent(match[1]) : null;
}

function setCookie(name: string, value: string, maxAgeSecs: number): void {
  const parts = [
    `${name}=${encodeURIComponent(value)}`,
    'path=/',
    `max-age=${maxAgeSecs}`,
    'SameSite=Strict',
  ];
  if (typeof window !== 'undefined' && window.location?.protocol === 'https:') {
    parts.push('Secure');
  }
  document.cookie = parts.join('; ');
}

export function getCookieValue(name: string): string | null {
  return getCookie(name);
}

export function setCookieValue(name: string, value: string, maxAgeSecs: number): void {
  setCookie(name, value, maxAgeSecs);
}

export function getToken(): string | null {
  return getCookie(TOKEN_KEY);
}

export function setToken(token: string, maxAgeSecs: number = SESSION_MAX_AGE_SECS): void {
  setCookie(TOKEN_KEY, token, maxAgeSecs);
}

export function clearToken(): void {
  setCookie(TOKEN_KEY, '', 0);
}

export function getUsername(): string | null {
  return localStorage.getItem(USERNAME_KEY);
}

export function setUsername(username: string): void {
  localStorage.setItem(USERNAME_KEY, username);
}

export function clearUsername(): void {
  localStorage.removeItem(USERNAME_KEY);
}

export function getEmail(): string | null {
  return localStorage.getItem(EMAIL_KEY);
}

export function setEmail(email: string): void {
  localStorage.setItem(EMAIL_KEY, email);
}

export function clearEmail(): void {
  localStorage.removeItem(EMAIL_KEY);
}

export function getPicture(): string | null {
  return localStorage.getItem(PICTURE_KEY);
}

export function setPicture(url: string): void {
  localStorage.setItem(PICTURE_KEY, url);
}

export function clearPicture(): void {
  localStorage.removeItem(PICTURE_KEY);
}

export function getAuthMethod(): AuthMethod | null {
  const value = localStorage.getItem(AUTH_METHOD_KEY);
  return value === 'local' || value === 'sso' ? value : null;
}

function decodeBase64Url(value: string): string | null {
  try {
    const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
    const padded = normalized + '='.repeat((4 - (normalized.length % 4 || 4)) % 4);
    return atob(padded);
  } catch {
    return null;
  }
}

export function detectAuthMethodFromToken(token: string | null): AuthMethod | null {
  if (!token) return null;
  const parts = token.split('.');
  if (parts.length < 2) return null;
  const headerJson = decodeBase64Url(parts[0]);
  if (!headerJson) return null;
  try {
    const header = JSON.parse(headerJson) as { alg?: string };
    if (header.alg === 'RS256') return 'sso';
    if (header.alg === 'HS256') return 'local';
  } catch {
    return null;
  }
  return null;
}

export function setAuthMethod(method: AuthMethod): void {
  localStorage.setItem(AUTH_METHOD_KEY, method);
}

export function clearAuthMethod(): void {
  localStorage.removeItem(AUTH_METHOD_KEY);
}

export function isLoggedIn(): boolean {
  return !!getToken();
}

export function clearAuth(): void {
  clearToken();
  clearUsername();
  clearEmail();
  clearPicture();
  clearAuthMethod();
}
