import { NavLink, Outlet, useLocation } from 'react-router-dom';
import styles from './Layout.module.css';

const NAV = [
  { to: '/',         end: true,  label: 'Dashboard', icon: 'fa-home' },
  { to: '/sites',    end: false, label: 'Sites',     icon: 'fa-globe' },
  { to: '/certificates', end: false, label: 'Certificates', icon: 'fa-certificate' },
  { to: '/dns-providers', end: false, label: 'DNS Providers', icon: 'fa-network-wired' },
  { to: '/metrics',  end: false, label: 'Metrics',   icon: 'fa-chart-line' },
  { to: '/settings', end: false, label: 'Settings',  icon: 'fa-cog' },
];

function useBreadcrumb(pathname: string) {
  const match = NAV.find(n => n.to !== '/' && pathname.startsWith(n.to));
  if (match) return { label: match.label, icon: match.icon };
  return { label: 'Dashboard', icon: 'fa-home' };
}

export default function Layout() {
  const { pathname } = useLocation();
  const crumb = useBreadcrumb(pathname);

  return (
    <div className={styles.root}>
      <aside className={styles.sidebar}>
        <div className={styles.logo}>
          <div className={styles.logoIcon}>
            <i className="fas fa-exchange-alt" />
          </div>
          <div>
            <div className={styles.logoText}>eProxy</div>
            <div className={styles.logoSub}>Pertisk · Erlang</div>
          </div>
        </div>

        <nav className={styles.nav}>
          <div className={styles.navSection}>
            <div className={styles.navSectionLabel}>Proxy</div>
            {NAV.slice(0, 4).map(n => (
              <NavLink
                key={n.to}
                to={n.to}
                end={n.end}
                className={({ isActive }) =>
                  `${styles.navLink}${isActive ? ' ' + styles.active : ''}`
                }
              >
                <i className={`fas ${n.icon}`} />
                {n.label}
              </NavLink>
            ))}
          </div>
          <div className={styles.navSection}>
            <div className={styles.navSectionLabel}>System</div>
            {NAV.slice(4).map(n => (
              <NavLink
                key={n.to}
                to={n.to}
                end={n.end}
                className={({ isActive }) =>
                  `${styles.navLink}${isActive ? ' ' + styles.active : ''}`
                }
              >
                <i className={`fas ${n.icon}`} />
                {n.label}
              </NavLink>
            ))}
          </div>
        </nav>
      </aside>

      <div className={styles.main}>
        <header className={styles.topbar}>
          <div className={styles.breadcrumb}>
            <i className={`fas ${crumb.icon}`} />
            <span>{crumb.label}</span>
          </div>
        </header>
        <main className={styles.content}>
          <Outlet />
        </main>
      </div>
    </div>
  );
}
