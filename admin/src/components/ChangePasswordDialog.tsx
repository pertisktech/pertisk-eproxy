import FaIcon from "@/components/FaIcon";
import { useState, useEffect, FormEvent } from 'react';
import { api } from '@/api/client';
import { useToast } from '@/context/ToastContext';
import styles from './ChangePasswordDialog.module.css';

export interface ChangePasswordDialogProps {
  open: boolean;
  onClose: () => void;
}

type PasswordStrength = 'weak' | 'medium' | 'strong';

function calculatePasswordStrength(password: string): PasswordStrength {
  if (password.length === 0) return 'weak';
  
  let score = 0;
  if (password.length >= 8) score++;
  if (password.length >= 12) score++;
  if (/[a-z]/.test(password) && /[A-Z]/.test(password)) score++;
  if (/\d/.test(password)) score++;
  if (/[^a-zA-Z0-9]/.test(password)) score++;
  
  if (score <= 2) return 'weak';
  if (score <= 4) return 'medium';
  return 'strong';
}

function getStrengthColor(strength: PasswordStrength): string {
  switch (strength) {
    case 'weak': return '#ef4444';
    case 'medium': return '#f59e0b';
    case 'strong': return '#10b981';
  }
}

function getStrengthWidth(strength: PasswordStrength): string {
  switch (strength) {
    case 'weak': return '33%';
    case 'medium': return '66%';
    case 'strong': return '100%';
  }
}

export default function ChangePasswordDialog({ open, onClose }: ChangePasswordDialogProps) {
  const toast = useToast();
  const [currentPassword, setCurrentPassword] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [showCurrent, setShowCurrent] = useState(false);
  const [showNew, setShowNew] = useState(false);
  const [showConfirm, setShowConfirm] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [touched, setTouched] = useState({
    current: false,
    new: false,
    confirm: false,
  });

  const passwordStrength = calculatePasswordStrength(newPassword);
  const strengthColor = getStrengthColor(passwordStrength);
  const strengthWidth = getStrengthWidth(passwordStrength);

  useEffect(() => {
    if (!open) {
      // Reset form when dialog closes
      setCurrentPassword('');
      setNewPassword('');
      setConfirmPassword('');
      setShowCurrent(false);
      setShowNew(false);
      setShowConfirm(false);
      setError(null);
      setLoading(false);
      setTouched({ current: false, new: false, confirm: false });
      document.body.style.overflow = '';
    } else {
      document.body.style.overflow = 'hidden';
    }
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const handleEscape = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !loading) onClose();
    };
    document.addEventListener('keydown', handleEscape);
    return () => document.removeEventListener('keydown', handleEscape);
  }, [open, loading, onClose]);

  // Clear general error when user starts typing
  useEffect(() => {
    if (error && (currentPassword || newPassword || confirmPassword)) {
      setError(null);
    }
  }, [currentPassword, newPassword, confirmPassword, error]);

  const getFieldError = (field: 'current' | 'new' | 'confirm'): string | null => {
    if (!touched[field]) return null;
    
    switch (field) {
      case 'current':
        return currentPassword.length === 0 ? 'Current password is required' : null;
      case 'new':
        if (newPassword.length === 0) return 'New password is required';
        if (newPassword.length < 4) return 'Password must be at least 4 characters';
        if (newPassword === currentPassword) return 'New password must be different';
        return null;
      case 'confirm':
        if (confirmPassword.length === 0) return 'Please confirm your password';
        if (confirmPassword !== newPassword) return 'Passwords do not match';
        return null;
    }
  };

  const handleBlur = (field: 'current' | 'new' | 'confirm') => {
    setTouched(prev => ({ ...prev, [field]: true }));
  };

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);

    // Mark all fields as touched
    setTouched({ current: true, new: true, confirm: true });

    // Validate all fields
    if (currentPassword.length === 0) {
      setError('Current password is required');
      return;
    }

    if (newPassword.length < 4) {
      setError('New password must be at least 4 characters');
      return;
    }

    if (newPassword === currentPassword) {
      setError('New password must be different from current password');
      return;
    }

    if (newPassword !== confirmPassword) {
      setError('Passwords do not match');
      return;
    }

    setLoading(true);

    try {
      await api.changePassword(currentPassword, newPassword);
      toast.success('Password updated successfully');
      onClose();
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to update password';
      setError(message);
      toast.error(message);
    } finally {
      setLoading(false);
    }
  }

  if (!open) return null;

  const currentError = getFieldError('current');
  const newError = getFieldError('new');
  const confirmError = getFieldError('confirm');

  return (
    <div
      className={styles.overlay}
      onClick={(e) => {
        if (!loading && e.target === e.currentTarget) onClose();
      }}
      role="dialog"
      aria-modal="true"
      aria-labelledby="change-password-title"
    >
      <div
        className={styles.panel}
        onClick={(e) => e.stopPropagation()}
      >
        <div className={styles.header}>
          <div className={styles.iconWrapper}>
            <FaIcon className="fas fa-key" aria-hidden />
          </div>
          <h2 id="change-password-title" className={styles.title}>
            Change Password
          </h2>
          <p className={styles.subtitle}>
            Update your account password
          </p>
        </div>

        <form onSubmit={handleSubmit} className={styles.form}>
          {/* Current Password */}
          <div className={styles.field}>
            <label htmlFor="current-password" className={styles.label}>
              Current Password
            </label>
            <div className={styles.inputWrapper}>
              <input
                id="current-password"
                type={showCurrent ? 'text' : 'password'}
                autoComplete="current-password"
                value={currentPassword}
                onChange={(e) => setCurrentPassword(e.target.value)}
                onBlur={() => handleBlur('current')}
                className={`${styles.input} ${currentError ? styles.inputError : ''}`}
                placeholder="Enter current password"
                disabled={loading}
                required
              />
              <button
                type="button"
                className={styles.toggleBtn}
                onClick={() => setShowCurrent(!showCurrent)}
                tabIndex={-1}
                aria-label={showCurrent ? 'Hide password' : 'Show password'}
              >
                <FaIcon className={`fas ${showCurrent ? 'fa-eye-slash' : 'fa-eye'}`} aria-hidden />
              </button>
            </div>
            {currentError && (
              <p className={styles.fieldError} role="alert">
                <FaIcon className="fas fa-exclamation-circle" aria-hidden /> {currentError}
              </p>
            )}
          </div>

          {/* New Password */}
          <div className={styles.field}>
            <label htmlFor="new-password" className={styles.label}>
              New Password
            </label>
            <div className={styles.inputWrapper}>
              <input
                id="new-password"
                type={showNew ? 'text' : 'password'}
                autoComplete="new-password"
                value={newPassword}
                onChange={(e) => setNewPassword(e.target.value)}
                onBlur={() => handleBlur('new')}
                className={`${styles.input} ${newError ? styles.inputError : ''}`}
                placeholder="Enter new password"
                disabled={loading}
                required
                minLength={4}
              />
              <button
                type="button"
                className={styles.toggleBtn}
                onClick={() => setShowNew(!showNew)}
                tabIndex={-1}
                aria-label={showNew ? 'Hide password' : 'Show password'}
              >
                <FaIcon className={`fas ${showNew ? 'fa-eye-slash' : 'fa-eye'}`} aria-hidden />
              </button>
            </div>
            {newError && (
              <p className={styles.fieldError} role="alert">
                <FaIcon className="fas fa-exclamation-circle" aria-hidden /> {newError}
              </p>
            )}
            
            {/* Password Strength Indicator */}
            {newPassword.length > 0 && !newError && (
              <div className={styles.strengthWrapper}>
                <div className={styles.strengthBar}>
                  <div
                    className={styles.strengthFill}
                    style={{
                      width: strengthWidth,
                      backgroundColor: strengthColor,
                    }}
                  />
                </div>
                <span className={styles.strengthLabel} style={{ color: strengthColor }}>
                  {passwordStrength.charAt(0).toUpperCase() + passwordStrength.slice(1)} password
                </span>
              </div>
            )}
            
            <ul className={styles.hints}>
              <li className={newPassword.length >= 8 ? styles.hintValid : ''}>
                <FaIcon className={`fas ${newPassword.length >= 8 ? 'fa-check-circle' : 'fa-circle'}`} aria-hidden />
                At least 8 characters
              </li>
              <li className={/[A-Z]/.test(newPassword) && /[a-z]/.test(newPassword) ? styles.hintValid : ''}>
                <FaIcon className={`fas ${/[A-Z]/.test(newPassword) && /[a-z]/.test(newPassword) ? 'fa-check-circle' : 'fa-circle'}`} aria-hidden />
                Upper and lowercase letters
              </li>
              <li className={/\d/.test(newPassword) ? styles.hintValid : ''}>
                <FaIcon className={`fas ${/\d/.test(newPassword) ? 'fa-check-circle' : 'fa-circle'}`} aria-hidden />
                At least one number
              </li>
            </ul>
          </div>

          {/* Confirm Password */}
          <div className={styles.field}>
            <label htmlFor="confirm-password" className={styles.label}>
              Confirm New Password
            </label>
            <div className={styles.inputWrapper}>
              <input
                id="confirm-password"
                type={showConfirm ? 'text' : 'password'}
                autoComplete="new-password"
                value={confirmPassword}
                onChange={(e) => setConfirmPassword(e.target.value)}
                onBlur={() => handleBlur('confirm')}
                className={`${styles.input} ${confirmError ? styles.inputError : ''}`}
                placeholder="Confirm new password"
                disabled={loading}
                required
              />
              <button
                type="button"
                className={styles.toggleBtn}
                onClick={() => setShowConfirm(!showConfirm)}
                tabIndex={-1}
                aria-label={showConfirm ? 'Hide password' : 'Show password'}
              >
                <FaIcon className={`fas ${showConfirm ? 'fa-eye-slash' : 'fa-eye'}`} aria-hidden />
              </button>
            </div>
            {confirmError && (
              <p className={styles.fieldError} role="alert">
                <FaIcon className="fas fa-exclamation-circle" aria-hidden /> {confirmError}
              </p>
            )}
          </div>

          {/* General Error */}
          {error && (
            <div className={styles.errorAlert} role="alert">
              <FaIcon className="fas fa-exclamation-triangle" aria-hidden />
              <span>{error}</span>
            </div>
          )}

          {/* Actions */}
          <div className={styles.actions}>
            <button
              type="button"
              className={styles.cancelBtn}
              onClick={onClose}
              disabled={loading}
            >
              Cancel
            </button>
            <button
              type="submit"
              className={styles.submitBtn}
              disabled={loading}
            >
              {loading ? (
                <>
                  <FaIcon className="fas fa-spinner fa-spin" aria-hidden /> Updating…
                </>
              ) : (
                <>
                  <FaIcon className="fas fa-check" aria-hidden /> Update Password
                </>
              )}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
