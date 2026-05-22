import FaIcon from '@/components/FaIcon';
import brandMarkUrl from '@/assets/brand-mark.svg?url';
import { memo, type Ref } from 'react';
import { NavLink } from 'react-router-dom';
import type { ApiMode } from '@/context/ModeContext';
import styles from './Layout.module.css';

export const NAV_MAIN_ALL = [
  { to: '/', end: true, label: 'Dashboard', icon: 'fa-home' },
  { to: '/sites', end: false, label: 'Sites', icon: 'fa-globe' },
  { to: '/certificates', end: false, label: 'Certificates', icon: 'fa-certificate' },
  { to: '/dns-providers', end: false, label: 'DNS providers', icon: 'fa-server' },
] as const;

export type NavMainItem = (typeof NAV_MAIN_ALL)[number];

/** In ingress mode hide DNS providers (routing is via Kubernetes Ingress). */
export function getNavMain(mode: string): readonly NavMainItem[] {
  if (mode === 'ingress') {
    return NAV_MAIN_ALL.filter((item) => item.to !== '/dns-providers');
  }
  return NAV_MAIN_ALL;
}

export const NAV_BOTTOM = [
  { to: '/backup', end: false, label: 'Backup', icon: 'fa-download' },
  { to: '/metrics', end: false, label: 'Metrics', icon: 'fa-chart-line' },
  { to: '/logs', end: false, label: 'Logs', icon: 'fa-file-alt' },
  { to: '/settings', end: false, label: 'Settings', icon: 'fa-cog' },
];

export const ALL_NAV = [...NAV_MAIN_ALL, ...NAV_BOTTOM];

export type MainSidebarProps = {
  sidebarRef: Ref<HTMLElement>;
  collapsed: boolean;
  appVersion: string;
  mode: ApiMode | undefined;
  onToggleSidebar: () => void;
};

function MainSidebarInner({
  sidebarRef,
  collapsed,
  appVersion,
  mode,
  onToggleSidebar,
}: MainSidebarProps) {
  return (
    <aside ref={sidebarRef} className={styles.sidebar} aria-label="Main navigation">
      <div className={styles.sidebarBrand}>
        <div className={styles.sidebarBrandMain}>
          <NavLink to="/" end className={styles.sidebarLogo} title="eProxy">
            <img src={brandMarkUrl} alt="" className={styles.logoImg} width={32} height={32} />
            <span className={styles.sidebarBrandText}>
              <span className={styles.sidebarLogoText}>
                e<span className={styles.logoAccent}>Proxy</span>
                {!collapsed && appVersion ? <span className={styles.sidebarVersionInline}> {appVersion}</span> : null}
              </span>
            </span>
          </NavLink>
          <button
            type="button"
            onClick={onToggleSidebar}
            className={styles.sidebarTopToggle}
            title={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
            aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
          >
            <FaIcon className={`fas ${collapsed ? 'fa-chevron-right' : 'fa-chevron-left'}`} aria-hidden />
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
              title={collapsed ? label : undefined}
              className={({ isActive }) =>
                isActive ? `${styles.sidebarLink} ${styles.active}` : styles.sidebarLink
              }
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
              title={collapsed ? label : undefined}
              className={({ isActive }) =>
                isActive ? `${styles.sidebarLink} ${styles.active}` : styles.sidebarLink
              }
            >
              <FaIcon className={`fas ${icon} ${styles.sidebarIcon}`} size={18} aria-hidden />
              <span className={styles.sidebarLinkText}>{label}</span>
            </NavLink>
          ))}
        </nav>
      </div>
    </aside>
  );
}

export const MainSidebar = memo(MainSidebarInner);
