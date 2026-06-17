import FaIcon from "@/components/FaIcon";
import brandMarkUrl from '@/assets/brand-mark.svg?url';
import { useState, FormEvent, useEffect } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import { api, type AuthConfigResponse } from '@/api/client';
import {
  clearEmail as clearAuthEmail,
  clearPicture as clearAuthPicture,
  isLoggedIn,
  setAuthMethod,
  setEmail as setAuthEmail,
  setPicture as setAuthPicture,
  setToken,
  setUsername as setAuthUsername,
} from '@/auth';
import type { Auth0Client } from '@auth0/auth0-spa-js';
import { getAuth0Client } from '@/sso';
import { useTheme } from '@/context/ThemeContext';
import { useToast } from '@/context/ToastContext';
import styles from './Login.module.css';

type Auth0EnabledConfig = AuthConfigResponse & {
  auth0_domain: string;
  auth0_client_id: string;
};

function tokenTtlSeconds(token: string): number {
  try {
    const parts = token.split('.');
    if (parts.length < 2) return 60 * 60;
    const payload = JSON.parse(atob(parts[1].replace(/-/g, '+').replace(/_/g, '/')));
    if (typeof payload?.exp !== 'number') return 60 * 60;
    const now = Math.floor(Date.now() / 1000);
    return Math.max(30, payload.exp - now);
  } catch {
    return 60 * 60;
  }
}

function supportsSso(config: AuthConfigResponse | null): boolean {
  return !!config?.supports_sso;
}

function supportsLocal(config: AuthConfigResponse | null): boolean {
  return !!config?.supports_local;
}

function isAuth0Configured(config: AuthConfigResponse | null): config is Auth0EnabledConfig {
  return !!config?.auth0_domain && !!config?.auth0_client_id;
}

/** Auth0 often returns an opaque access token without an API audience; eProxy verifies JWTs only, so prefer the ID token. */
function isLikelyJwt(token: string): boolean {
  return token.split('.').length === 3;
}

async function getBearerJwtForApi(client: Auth0Client, cfg: Auth0EnabledConfig): Promise<string> {
  if (cfg.auth0_audience) {
    try {
      const access = await client.getTokenSilently({
        authorizationParams: { audience: cfg.auth0_audience },
      });
      if (access && isLikelyJwt(access)) {
        return access;
      }
    } catch {
      /* try id token below */
    }
  }

  const idClaims = await client.getIdTokenClaims();
  const rawId = idClaims?.__raw;
  if (rawId && isLikelyJwt(rawId)) {
    return rawId;
  }

  const access = await client.getTokenSilently(
    cfg.auth0_audience ? { authorizationParams: { audience: cfg.auth0_audience } } : {},
  );
  if (access && isLikelyJwt(access)) {
    return access;
  }

  if (rawId) {
    return rawId;
  }

  throw new Error(
    'Auth0 did not return a JWT for API calls. Create an Auth0 API, set admin_auth0_audience on the server, or ensure OpenID returns an ID token.',
  );
}

export default function Login() {
  const navigate = useNavigate();
  const theme = useTheme();
  const toast = useToast();
  const [version, setVersion] = useState<string | null>(null);
  const [authConfig, setAuthConfig] = useState<AuthConfigResponse | null>(null);
  const [ssoLoading, setSsoLoading] = useState(false);
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const qs = new URLSearchParams(window.location.search);
    if (qs.has('code') && qs.has('state')) {
      return;
    }
    if (isLoggedIn()) navigate('/', { replace: true });
  }, [navigate]);

  useEffect(() => {
    api.version().then((r) => setVersion(r.version)).catch(() => {});
    api.authConfig().then(setAuthConfig).catch(() => {});
  }, []);

  useEffect(() => {
    let cancelled = false;
    async function maybeHandleAuth0Redirect() {
      if (!authConfig || !supportsSso(authConfig) || !isAuth0Configured(authConfig)) return;
      const params = new URLSearchParams(window.location.search);
      if (!params.has('code') || !params.has('state')) return;

      const state = params.get('state')!;
      const dedupeKey = `eproxy_auth0_cb_ok_${state}`;
      if (sessionStorage.getItem(dedupeKey) === '1') {
        window.history.replaceState({}, document.title, `${window.location.pathname}`);
        if (isLoggedIn()) {
          navigate('/', { replace: true });
        }
        return;
      }

      setSsoLoading(true);
      setError(null);
      try {
        const client = await getAuth0Client({
          domain: authConfig.auth0_domain!,
          clientId: authConfig.auth0_client_id!,
          audience: authConfig.auth0_audience,
        });
        await client.handleRedirectCallback(window.location.href);
        const token = await getBearerJwtForApi(client, authConfig);
        if (cancelled) return;
        setToken(token, tokenTtlSeconds(token));
        sessionStorage.setItem(dedupeKey, '1');
        window.history.replaceState({}, document.title, `${window.location.pathname}`);
        setAuthMethod('sso');
        const user = await client.getUser();
        if (user?.email || user?.name || user?.sub) {
          setAuthUsername((user.email as string) || (user.name as string) || user.sub || 'sso');
        }
        if (user?.email) setAuthEmail(user.email as string);
        if (user?.picture) setAuthPicture(user.picture as string);
        toast.success('Signed in with SSO');
        navigate('/', { replace: true });
      } catch (err) {
        if (cancelled) return;
        const msg = err instanceof Error ? err.message : 'SSO login failed';
        setError(msg);
        toast.error(msg);
      } finally {
        if (!cancelled) setSsoLoading(false);
      }
    }
    maybeHandleAuth0Redirect();
    return () => {
      cancelled = true;
    };
  }, [authConfig, navigate, toast]);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      const res = await api.login(username, password);
      setToken(res.token, res.expires_in);
      setAuthMethod('local');
      clearAuthEmail();
      clearAuthPicture();
      if (res.username) setAuthUsername(res.username);
      toast.success('Signed in');
      navigate('/', { replace: true });
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Login failed';
      const displayMsg =
        msg === 'login requires database' || msg === 'login not configured'
          ? 'Login is unavailable: local auth is not enabled on this server.'
          : msg;
      setError(displayMsg);
      toast.error(displayMsg);
    } finally {
      setLoading(false);
    }
  }

  async function handleSsoLogin() {
    if (!authConfig || !supportsSso(authConfig) || !isAuth0Configured(authConfig)) {
      const msg = 'Auth0 SSO is not configured on the server.';
      setError(msg);
      toast.error(msg);
      return;
    }
    setError(null);
    setSsoLoading(true);
    try {
      const client = await getAuth0Client({
        domain: authConfig.auth0_domain,
        clientId: authConfig.auth0_client_id,
        audience: authConfig.auth0_audience,
      });
      await client.loginWithRedirect({
        ...(authConfig.auth0_audience
          ? { authorizationParams: { audience: authConfig.auth0_audience } }
          : {}),
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'SSO login failed';
      setError(msg);
      toast.error(msg);
      setSsoLoading(false);
    }
  }

  return (
    <div className={styles.wrap}>
      <header className={styles.topBar}>
        <span className={styles.topBarSpacer} />
        {theme && (
          <button
            type="button"
            className={styles.themeToggle}
            onClick={theme.toggleTheme}
            title={theme.isDark ? 'Light mode' : 'Dark mode'}
            aria-label={theme.isDark ? 'Switch to light mode' : 'Switch to dark mode'}
          >
            <FaIcon className={theme.isDark ? 'fas fa-sun' : 'fas fa-moon'} aria-hidden />
            <span className={styles.themeToggleLabel}>{theme.isDark ? 'Light' : 'Dark'}</span>
          </button>
        )}
      </header>

      <div className={styles.brand}>
        <img src={brandMarkUrl} alt="" className={styles.brandLogo} width={48} height={48} />
        <span className={styles.brandName}>eProxy</span>
      </div>

      <div className={styles.card}>
        <div className={styles.cardHeader}>
          <h1 className={styles.title}>
            <FaIcon className={`fas fa-shield-alt ${styles.titleIcon}`} aria-hidden />
            Welcome Back
          </h1>
          <p className={styles.subtitle}>Sign in to manage your edge proxy dashboard</p>
        </div>

        <form onSubmit={handleSubmit} className={styles.form}>
          {supportsLocal(authConfig) && (
            <>
              <label className={styles.label}>
                Username
                <input
                  type="text"
                  autoComplete="username"
                  value={username}
                  onChange={(e) => setUsername(e.target.value)}
                  className={styles.input}
                  placeholder="Enter username"
                  required
                />
              </label>
              <label className={styles.label}>
                Password
                <input
                  type="password"
                  autoComplete="current-password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  className={styles.input}
                  placeholder="Enter password"
                  required
                />
              </label>
            </>
          )}
          {error && <p className={styles.error}>{error}</p>}
          {supportsLocal(authConfig) && (
            <button type="submit" className={styles.button} disabled={loading || ssoLoading}>
              {loading ? 'Logging in…' : 'Login'}
            </button>
          )}
          {supportsSso(authConfig) && (
            <button
              type="button"
              className={styles.buttonSecondary}
              onClick={handleSsoLogin}
              disabled={loading || ssoLoading}
            >
              {ssoLoading ? 'Redirecting…' : 'Sign in with SSO (Auth0)'}
            </button>
          )}
          {authConfig?.guest_mode && (
            <p className={styles.hint}>
              Guest mode: the API accepts requests without login.{' '}
              <Link to="/">Open dashboard →</Link>
            </p>
          )}
          {authConfig && !supportsLocal(authConfig) && !supportsSso(authConfig) && !authConfig.guest_mode && (
            <p className={styles.hint}>No login method is enabled for this deployment.</p>
          )}
        </form>
      </div>

      {version ? (
        <footer className={styles.footer}>
          <p className={styles.version}>
            Pertisk eProxy {version.startsWith('v') ? version : `v${version}`}
          </p>
        </footer>
      ) : null}
    </div>
  );
}
