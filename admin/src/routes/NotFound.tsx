import FaIcon from "@/components/FaIcon";
import { Link } from 'react-router-dom';
import styles from './NotFound.module.css';

export default function NotFound() {
  return (
    <section className={styles.section} aria-label="Not found">
      <h2 className={styles.title}>
        <FaIcon className="fas fa-exclamation-triangle" aria-hidden />
        Page not found
      </h2>

      <div className={styles.actions}>
        <Link to="/" className={styles.primary}>
          <FaIcon className="fas fa-home" aria-hidden />
          Go to dashboard
        </Link>
        <Link to="/login" className={styles.secondary}>
          <FaIcon className="fas fa-sign-in-alt" aria-hidden />
          Login
        </Link>
      </div>
    </section>
  );
}
