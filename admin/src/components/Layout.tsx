import FaIcon from "@/components/FaIcon";
import brandMarkUrl from '@/assets/brand-mark.svg?url';
import { useState, useEffect, useRef, useCallback } from 'react';
import { NavLink, Outlet, useNavigate, useLocation, Link } from 'react-router-dom';
import { api, openRealtimeStream, type CertificateRow, type LogEntry, type RealtimeSnapshot } from '@/api/client';
import {
  detectAuthMethodFromToken,
  getAuthMethod,
  getToken,
  isLoggedIn,
  getUsername,
  setUsername,
  setToken,
  clearAuth,
  DEFAULT_SESSION_TTL_SECS,
} from '@/auth';
import { getEmail, getPicture } from '@/auth';
import { AuthProvider } from '@/context/AuthContext';
import { ModeContext, type ApiMode } from '@/context/ModeContext';
import { useTheme } from '@/context/ThemeContext';
import { useToast } from '@/context/ToastContext';
import ChangePasswordDialog from './ChangePasswordDialog';
import styles from './Layout.module.css';

const SIDEBAR_STORAGE_KEY = 'pertisk_sidebar_collapsed';
const SIDEBAR_WIDTH_STORAGE_KEY = 'pertisk_sidebar_width';
const SIDEBAR_DEFAULT_WIDTH = 270;
const SIDEBAR_MIN_WIDTH = 230;
const SIDEBAR_MAX_WIDTH = 420;

function clampSidebarWidth(width: number): number {
  return Math.min(SIDEBAR_MAX_WIDTH, Math.max(SIDEBAR_MIN_WIDTH, width));
}

function getSidebarCollapsed(): boolean {
  try {
    return localStorage.getItem(SIDEBAR_STORAGE_KEY) === 'true';
  } catch {
    return false;
  }
}

function getSidebarWidth(): number {
  try {
    const raw = localStorage.getItem(SIDEBAR_WIDTH_STORAGE_KEY);
    const parsed = Number(raw);
    if (!Number.isFinite(parsed)) {
      return SIDEBAR_DEFAULT_WIDTH;
    }
    return clampSidebarWidth(parsed);
  } catch {
    return SIDEBAR_DEFAULT_WIDTH;
  }
}

const NAV_MAIN_ALL = [
  { to: '/', end: true, label: 'Dashboard', icon: 'fa-home' },
  { to: '/sites', end: false, label: 'Sites', icon: 'fa-globe' },
  { to: '/certificates', end: false, label: 'Certificates', icon: 'fa-certificate' },
  { to: '/dns-providers', end: false, label: 'DNS providers', icon: 'fa-server' },
] as const;

type NavMainItem = (typeof NAV_MAIN_ALL)[number];

/** eProxy: always full proxy nav (no Helm / no ingress-only views). */
function getNavMain(_mode: string): readonly NavMainItem[] {
  return NAV_MAIN_ALL;
}

const NAV_BOTTOM = [
  { to: '/backup', end: false, label: 'Backup', icon: 'fa-download' },
  { to: '/metrics', end: false, label: 'Metrics', icon: 'fa-chart-line' },
  { to: '/logs', end: false, label: 'Logs', icon: 'fa-file-alt' },
  { to: '/settings', end: false, label: 'Settings', icon: 'fa-cog' },
];

const NAV_DOCS = [
  { href: '/api/docs', label: 'API docs', icon: 'fa-book' },
];

const ALL_NAV = [
  ...NAV_MAIN_ALL,
  ...NAV_BOTTOM,
];

interface BreadcrumbItem {
  label: string;
  icon: string;
  path?: string;
}

function useBreadcrumbs(pathname: string): BreadcrumbItem[] {
  const siteDetailMatch = /^\/sites\/([^/]+)$/.exec(pathname);
  if (siteDetailMatch && siteDetailMatch[1]) {
    try {
      const host = decodeURIComponent(siteDetailMatch[1]);
      return [
        { label: 'Sites', icon: 'fa-globe', path: '/sites' },
        { label: host, icon: 'fa-server' },
      ];
    } catch {
      /* fall through */
    }
  }
  const match = ALL_NAV.find(
    (item) => 'to' in item && item.to !== '/' && (pathname === item.to || pathname.startsWith(item.to + '/'))
  );
  if (match && 'to' in match) return [{ label: match.label, icon: match.icon, path: match.to }];
  if (pathname === '/') return [{ label: 'Dashboard', icon: 'fa-home', path: '/' }];
  if (pathname.startsWith('/profile')) return [{ label: 'Profile', icon: 'fa-user' }];
  return [{ label: 'Dashboard', icon: 'fa-home', path: '/' }];
}

export default function Layout() {
  const navigate = useNavigate();
  const { pathname } = useLocation();
  const theme = useTheme();
  const toast = useToast();
  const [sidebarCollapsed, setSidebarCollapsed] = useState(getSidebarCollapsed);
  const [sidebarWidth, setSidebarWidth] = useState(getSidebarWidth);
  const [isSidebarResizing, setIsSidebarResizing] = useState(false);
  const [currentUser, setCurrentUser] = useState<string>(getUsername() || '');
  const [currentEmail, setCurrentEmail] = useState<string>(getEmail() || '');
  const [currentPicture, setCurrentPicture] = useState<string>(getPicture() || '');
  const [authMethod, setCurrentAuthMethod] = useState(getAuthMethod());
  const [mode, setMode] = useState<ApiMode | undefined>(undefined);
  const [appVersion, setAppVersion] = useState<string>('');
  const [showUserMenu, setShowUserMenu] = useState(false);
  const [showPasswordModal, setShowPasswordModal] = useState(false);
  const userMenuRef = useRef<HTMLDivElement>(null);
  const certsInitializedRef = useRef(false);
  const knownCertIdsRef = useRef<Set<string>>(new Set());
  const errorsInitializedRef = useRef(false);
  const lastErrorTsRef = useRef<number | null>(null);
  const refreshTimerRef = useRef<number | null>(null);
  const sidebarRef = useRef<HTMLElement>(null);
  const resizeCleanupRef = useRef<(() => void) | null>(null);

  const loggedIn = isLoggedIn();

  useEffect(() => {
    if (!loggedIn) return;
    let cancelled = false;
    api
      .authCheck()
      .then((data) => {
        if (!cancelled && data.authenticated && data.username) {
          setCurrentUser(data.username);
          setUsername(data.username);
        }
        const pic = getPicture();
        if (pic) setCurrentPicture(pic);
        const em = getEmail();
        if (em) setCurrentEmail(em);
        setCurrentAuthMethod(getAuthMethod());
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [loggedIn]);

  useEffect(() => {
    const effectiveAuthMethod = authMethod ?? detectAuthMethodFromToken(getToken());
    if (!loggedIn || effectiveAuthMethod !== 'local') {
      if (refreshTimerRef.current !== null) {
        window.clearTimeout(refreshTimerRef.current);
        refreshTimerRef.current = null;
      }
      return;
    }
    let cancelled = false;

    function scheduleNext(ttlSecs?: number) {
      const resolvedTtl = typeof ttlSecs === 'number' && ttlSecs > 0
        ? ttlSecs
        : DEFAULT_SESSION_TTL_SECS;
      const bufferSecs = Math.min(300, Math.max(30, Math.floor(resolvedTtl * 0.1)));
      const delaySecs = Math.max(resolvedTtl - bufferSecs, 30);
      if (refreshTimerRef.current !== null) {
        window.clearTimeout(refreshTimerRef.current);
      }
      refreshTimerRef.current = window.setTimeout(runRefresh, delaySecs * 1000);
    }

    async function runRefresh() {
      try {
        const res = await api.authRefresh();
        if (cancelled) return;
        if (res.token) {
          setToken(res.token, res.expires_in);
        }
        if (res.username) {
          setCurrentUser(res.username);
          setUsername(res.username);
        }
        scheduleNext(res.expires_in);
      } catch {
        // Auth refresh errors are handled by the API client (401 redirects).
      }
    }

    runRefresh();
    return () => {
      cancelled = true;
      if (refreshTimerRef.current !== null) {
        window.clearTimeout(refreshTimerRef.current);
        refreshTimerRef.current = null;
      }
    };
  }, [loggedIn, authMethod]);

  useEffect(() => {
    let cancelled = false;
    api
      .management()
      .then((info) => {
        if (!cancelled) {
          if (info.mode === 'proxy' || info.mode === 'ingress') {
            setMode(info.mode);
          }
          if (info.version) {
            setAppVersion(info.version.startsWith('v') ? info.version : `v${info.version}`);
          }
        }
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    if (!loggedIn) return;

    function formatCertHosts(hosts: CertificateRow['hosts']): string {
      if (!hosts?.length) return 'unknown host';
      if (hosts.length === 1) return hosts[0];
      return `${hosts[0]} +${hosts.length - 1} more`;
    }

    function parseTs(entry: LogEntry): number | null {
      const ts = Date.parse(entry.timestamp);
      return Number.isNaN(ts) ? null : ts;
    }

    function onRealtime(snapshot: RealtimeSnapshot) {
      const certRows = Array.isArray(snapshot.certificates) ? snapshot.certificates : [];
      if (!certsInitializedRef.current) {
        certsInitializedRef.current = true;
        knownCertIdsRef.current = new Set(certRows.map((row) => row.id));
      } else {
        const known = knownCertIdsRef.current;
        certRows.forEach((row) => {
          if (known.has(row.id)) return;
          known.add(row.id);
          // Skip manual listener PEM imports; that flow already shows its own toast.
          if (row.id === 'listener-tls' || row.source_type === 'tls_listener' || row.challenge === 'static PEM') {
            return;
          }
          toast.success(`SSL certificate issued for ${formatCertHosts(row.hosts)}.`);
        });
      }

      const entries = Array.isArray(snapshot.logs) ? snapshot.logs : [];
      const errors = entries.filter((e) => e.level === 'error' || e.type === 'error');
      const withTs = errors
        .map((e) => ({ entry: e, ts: parseTs(e) }))
        .filter((e): e is { entry: LogEntry; ts: number } => e.ts !== null);

      const maxTs = withTs.reduce((max, e) => Math.max(max, e.ts), -1);
      if (!errorsInitializedRef.current) {
        errorsInitializedRef.current = true;
        lastErrorTsRef.current = maxTs >= 0 ? maxTs : null;
        return;
      }
      if (maxTs < 0) return;

      const last = lastErrorTsRef.current ?? 0;
      const newErrors = withTs
        .filter((e) => e.ts > last)
        .sort((a, b) => a.ts - b.ts)
        .slice(0, 3);

      newErrors.forEach(({ entry }) => {
        const message = entry.message?.trim() || 'System error occurred.';
        toast.error(`System error: ${message}`);
      });
      lastErrorTsRef.current = Math.max(last, maxTs);
    }

    const stop = openRealtimeStream(onRealtime);
    return () => {
      stop();
    };
  }, [loggedIn, toast]);

  useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (userMenuRef.current && !userMenuRef.current.contains(e.target as Node)) {
        setShowUserMenu(false);
      }
    }
    document.addEventListener('click', handleClickOutside);
    return () => document.removeEventListener('click', handleClickOutside);
  }, []);

  useEffect(() => {
    try {
      localStorage.setItem(SIDEBAR_WIDTH_STORAGE_KEY, String(sidebarWidth));
    } catch {}
  }, [sidebarWidth]);

  const updateSidebarWidthFromClientX = useCallback((clientX: number) => {
    const sidebarLeft = sidebarRef.current?.getBoundingClientRect().left ?? 0;
    const viewportMax = Math.max(SIDEBAR_MIN_WIDTH, Math.floor(window.innerWidth * 0.5));
    const maxWidth = Math.min(SIDEBAR_MAX_WIDTH, viewportMax);
    const nextWidth = Math.min(maxWidth, Math.max(SIDEBAR_MIN_WIDTH, clientX - sidebarLeft));
    setSidebarWidth(nextWidth);
  }, []);

  useEffect(() => {
    return () => {
      resizeCleanupRef.current?.();
      resizeCleanupRef.current = null;
    };
  }, []);

  async function handleLogout() {
    try {
      await api.logout();
    } catch {
      // ignore
    }
    clearAuth();
    setCurrentUser('');
    setCurrentEmail('');
    setCurrentPicture('');
    setCurrentAuthMethod(null);
    setShowUserMenu(false);
    navigate('/login', { replace: true });
  }

  function openPasswordModal() {
    setShowUserMenu(false);
    setShowPasswordModal(true);
  }

  function closePasswordModal() {
    setShowPasswordModal(false);
  }

  function toggleSidebar() {
    const next = !sidebarCollapsed;
    setSidebarCollapsed(next);
    try {
      localStorage.setItem(SIDEBAR_STORAGE_KEY, String(next));
    } catch {}
  }

  function startSidebarResize(event: React.PointerEvent<HTMLDivElement>) {
    if (sidebarCollapsed) return;
    if (event.button !== 0) return;
    event.preventDefault();
    resizeCleanupRef.current?.();
    updateSidebarWidthFromClientX(event.clientX);
    event.currentTarget.setPointerCapture(event.pointerId);
    setIsSidebarResizing(true);

    const pointerId = event.pointerId;
    const onPointerMove = (moveEvent: PointerEvent) => {
      if (moveEvent.pointerId !== pointerId) return;
      moveEvent.preventDefault();
      updateSidebarWidthFromClientX(moveEvent.clientX);
    };
    const stop = () => {
      setIsSidebarResizing(false);
      window.removeEventListener('pointermove', onPointerMove);
      window.removeEventListener('pointerup', onPointerUp);
      window.removeEventListener('pointercancel', onPointerUp);
      window.removeEventListener('mousemove', onMouseMove);
      window.removeEventListener('mouseup', onMouseUp);
      resizeCleanupRef.current = null;
    };
    const onPointerUp = (upEvent: PointerEvent) => {
      if (upEvent.pointerId !== pointerId) return;
      stop();
    };
    const onMouseMove = (moveEvent: MouseEvent) => {
      moveEvent.preventDefault();
      updateSidebarWidthFromClientX(moveEvent.clientX);
    };
    const onMouseUp = () => {
      stop();
    };

    window.addEventListener('pointermove', onPointerMove);
    window.addEventListener('pointerup', onPointerUp);
    window.addEventListener('pointercancel', onPointerUp);
    window.addEventListener('mousemove', onMouseMove);
    window.addEventListener('mouseup', onMouseUp);
    resizeCleanupRef.current = stop;
  }

  const initial = currentUser ? currentUser.charAt(0).toUpperCase() : 'U';
  const modeLabel = mode === 'ingress' ? 'Ingress mode' : 'Erlang proxy';
  const breadcrumbs = useBreadcrumbs(pathname);
  const effectiveAuthMethod = authMethod ?? detectAuthMethodFromToken(getToken());
  const canChangePassword = mode !== 'ingress' && effectiveAuthMethod !== 'sso';
  const displayIdentity = currentEmail || currentUser || 'User';

  return (
    <ModeContext.Provider value={mode}>
    <div
      className={`${styles.wrap} ${sidebarCollapsed ? styles.wrapCollapsed : ''} ${isSidebarResizing ? styles.wrapResizing : ''}`}
      style={{ '--sidebar-width': `${sidebarWidth}px` } as React.CSSProperties}
    >
      <aside ref={sidebarRef} className={styles.sidebar} aria-label="Main navigation">
        <div className={styles.sidebarBrand}>
          <div className={styles.sidebarBrandMain}>
            <NavLink to="/" end className={styles.sidebarLogo} title="eProxy">
              <img src={brandMarkUrl} alt="" className={styles.logoImg} width={32} height={32} />
              <span className={styles.sidebarBrandText}>
                <span className={styles.sidebarLogoText}>
                  e<span className={styles.logoAccent}>Proxy</span>
                  {!sidebarCollapsed && appVersion ? <span className={styles.sidebarVersionInline}> {appVersion}</span> : null}
                </span>
              </span>
            </NavLink>
            <button
              type="button"
              onClick={toggleSidebar}
              className={styles.sidebarTopToggle}
              title={sidebarCollapsed ? 'Expand sidebar' : 'Collapse sidebar'}
              aria-label={sidebarCollapsed ? 'Expand sidebar' : 'Collapse sidebar'}
            >
              <FaIcon className={`fas ${sidebarCollapsed ? 'fa-chevron-right' : 'fa-chevron-left'}`} aria-hidden />
            </button>
          </div>
        </div>
        <div className={styles.navSection}>
          <div className={styles.navSectionLabel}>Configuration</div>
          <nav className={styles.sidebarNav}>
        {getNavMain(mode ?? 'proxy').map(({ to, end, label, icon }) => (
              <NavLink
                key={to}
                to={to}
                end={end}
                title={sidebarCollapsed ? label : undefined}
                className={({ isActive }) => (isActive ? `${styles.sidebarLink} ${styles.active}` : styles.sidebarLink)}
              >
                <FaIcon className={`fas ${icon} ${styles.sidebarIcon}`} size={18} aria-hidden />
                <span className={styles.sidebarLinkText}>{label}</span>
              </NavLink>
            ))}
          </nav>
        </div>
        <div className={styles.navSection}>
          <div className={styles.navSectionLabel}>Operations</div>
          <nav className={styles.sidebarNavBottom}>
            {NAV_BOTTOM.map(({ to, end, label, icon }) => (
              <NavLink
                key={to}
                to={to}
                end={end}
                title={sidebarCollapsed ? label : undefined}
                className={({ isActive }) => (isActive ? `${styles.sidebarLink} ${styles.active}` : styles.sidebarLink)}
              >
                <FaIcon className={`fas ${icon} ${styles.sidebarIcon}`} size={18} aria-hidden />
                <span className={styles.sidebarLinkText}>{label}</span>
              </NavLink>
            ))}
          </nav>
        </div>
        <div className={styles.navSection}>
          <div className={styles.navSectionLabel}>Reference</div>
          <nav className={styles.sidebarNavBottom}>
            {NAV_DOCS.map(({ href, label, icon }) => (
              <a
                key={href}
                href={href}
                target="_blank"
                rel="noopener noreferrer"
                title={sidebarCollapsed ? label : undefined}
                className={styles.sidebarLink}
              >
                <FaIcon className={`fas ${icon} ${styles.sidebarIcon}`} size={18} aria-hidden />
                <span className={styles.sidebarLinkText}>{label}</span>
              </a>
            ))}
          </nav>
        </div>
      </aside>
      <div
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize sidebar"
        className={`${styles.sidebarResizeHandle} ${sidebarCollapsed ? styles.sidebarResizeHandleHidden : ''}`}
        onPointerDown={startSidebarResize}
      />

      <div className={styles.content}>
        <div className={styles.utilityBar}>
          <nav className={styles.breadcrumb} aria-label="Breadcrumb">
            <ol className={styles.breadcrumbList}>
              {breadcrumbs.map((crumb, index) => {
                const isLast = index === breadcrumbs.length - 1;
                return (
                  <li key={crumb.label} className={styles.breadcrumbItem}>
                    {index > 0 && <span className={styles.breadcrumbSep}>/</span>}
                    <FaIcon className={`fas ${crumb.icon} ${styles.breadcrumbIcon}`} size={14} aria-hidden />
                    {crumb.path && !isLast ? (
                      <Link to={crumb.path} className={styles.breadcrumbLink}>{crumb.label}</Link>
                    ) : (
                      <span className={isLast ? styles.breadcrumbCurrent : styles.breadcrumbLink}>{crumb.label}</span>
                    )}
                  </li>
                );
              })}
            </ol>
          </nav>
          <div className={styles.utilityBarRight}>
          {mode && <span className={styles.modeBadge}>{modeLabel}</span>}
          {theme && (
            <button
              type="button"
              className={styles.themeBtn}
              onClick={theme.toggleTheme}
              title={theme.isDark ? 'Light mode' : 'Dark mode'}
              aria-label={theme.isDark ? 'Switch to light mode' : 'Switch to dark mode'}
            >
              <FaIcon className={theme.isDark ? 'fas fa-sun' : 'fas fa-moon'} aria-hidden />
            </button>
          )}
          {loggedIn && (
            <div className={styles.userMenuWrap} ref={userMenuRef}>
              <button
                type="button"
                onClick={() => setShowUserMenu(!showUserMenu)}
                className={`${styles.userButton} ${showUserMenu ? styles.userButtonOpen : ''}`}
                aria-expanded={showUserMenu}
                aria-haspopup="true"
                aria-controls="user-menu"
                id="user-menu-trigger"
              >
                {currentPicture ? (
                  <img src={currentPicture} alt="" className={styles.userAvatarImg} />
                ) : (
                  <span className={styles.userAvatar}>{initial}</span>
                )}
                <span className={styles.userName}>{displayIdentity}</span>
                <FaIcon className={`fas fa-chevron-down ${styles.userChevron}`} aria-hidden />
              </button>
              <div
                id="user-menu"
                className={`${styles.userDropdown} ${showUserMenu ? styles.userDropdownOpen : ''}`}
                role="menu"
                aria-labelledby="user-menu-trigger"
                aria-hidden={!showUserMenu}
              >
                <div className={styles.userDropdownProfile}>
                  {currentPicture ? (
                    <img src={currentPicture} alt="" className={styles.userDropdownAvatar} />
                  ) : (
                    <span className={styles.userDropdownAvatarInitial}>{initial}</span>
                  )}
                  <div className={styles.userDropdownProfileInfo}>
                    <span className={styles.userDropdownName}>{displayIdentity}</span>
                  </div>
                </div>
                <div className={styles.userDropdownDivider} aria-hidden />
                <NavLink
                  to="/profile"
                  className={styles.userDropdownItem}
                  onClick={(e) => {
                    e.stopPropagation();
                    setShowUserMenu(false);
                  }}
                  role="menuitem"
                >
                  <FaIcon className="fas fa-user" aria-hidden />
                  <span>Profile</span>
                </NavLink>
                <div className={styles.userDropdownDivider} aria-hidden />
                {canChangePassword && (
                  <button
                    type="button"
                    className={styles.userDropdownItem}
                    onClick={(e) => {
                      e.stopPropagation();
                      openPasswordModal();
                    }}
                    role="menuitem"
                  >
                    <FaIcon className="fas fa-key" aria-hidden />
                    <span>Change password</span>
                  </button>
                )}
                <button
                  type="button"
                  className={styles.userDropdownItem}
                  onClick={(e) => {
                    e.stopPropagation();
                    handleLogout();
                  }}
                  role="menuitem"
                >
                  <FaIcon className="fas fa-sign-out-alt" aria-hidden />
                  <span>Log out</span>
                </button>
              </div>
            </div>
          )}
          </div>
        </div>
        <main id="layout-main-scroll" className={styles.main}>
          <div className={styles.mainAmbient} aria-hidden />
          <div className={styles.mainContent}>
            <div className={styles.mainContentInner}>
              <AuthProvider value={{ openPasswordModal }}>
                <Outlet />
              </AuthProvider>
            </div>
          </div>
        </main>
      </div>

      {canChangePassword && (
        <ChangePasswordDialog 
          open={showPasswordModal} 
          onClose={closePasswordModal} 
        />
      )}
    </div>
    </ModeContext.Provider>
  );
}
