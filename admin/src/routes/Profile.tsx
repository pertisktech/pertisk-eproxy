import { useAuth } from '@/context/AuthContext';
import { useIsIngressMode } from '@/context/ModeContext';
import { detectAuthMethodFromToken, getAuthMethod, getEmail, getPicture, getToken, getUsername } from '@/auth';
import styles from './Profile.module.css';

export default function Profile() {
  const auth = useAuth();
  const isIngressMode = useIsIngressMode();
  const username = getUsername() || '';
  const email = getEmail() || '';
  const picture = getPicture() || '';
  const authMethod = getAuthMethod() ?? detectAuthMethodFromToken(getToken());
  const canChangePassword = !isIngressMode && authMethod !== 'sso';
  const displayIdentity = email || username || '—';
  const initial = (email || username || 'U').charAt(0).toUpperCase();

  return (
    <section className={styles.section}>
      <div className={styles.card}>
        {picture ? (
          <img src={picture} alt="" className={styles.avatarImage} />
        ) : (
          <div className={styles.avatar}>{initial}</div>
        )}
        <div className={styles.info}>
          <p className={styles.label}>Email</p>
          <p className={styles.value}>{displayIdentity}</p>
          <p className={styles.role}>Administrator</p>
        </div>
        {auth && canChangePassword && (
          <button
            type="button"
            className={styles.changePasswordBtn}
            onClick={auth.openPasswordModal}
          >
            Change password
          </button>
        )}
      </div>
    </section>
  );
}
