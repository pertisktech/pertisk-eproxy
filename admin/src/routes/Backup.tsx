import { useState } from 'react';
import { useMode } from '@/context/ModeContext';
import { useToast } from '@/context/ToastContext';
import { getToken } from '@/auth';
import styles from './Backup.module.css';

export default function Backup() {
  const token = getToken();
  const mode = useMode();
  const toast = useToast();
  const [isExporting, setIsExporting] = useState(false);
  const [isRestoring, setIsRestoring] = useState(false);
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [mergeMode, setMergeMode] = useState(false);

  const isIngressMode = mode === 'ingress';
  const fileExtension = isIngressMode ? '.yaml' : '.json';
  const fileType = isIngressMode ? 'YAML' : 'JSON';

  const handleExport = async () => {
    setIsExporting(true);

    try {
      const headers: Record<string, string> = {};
      if (token) {
        headers['Authorization'] = `Bearer ${token}`;
      }
      const response = await fetch('/api/backup/export', {
        headers,
      });

      if (!response.ok) {
        throw new Error('Failed to export backup');
      }

      const blob = await response.blob();
      const url = window.URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `pertisk-${mode || 'proxy'}-backup-${new Date().toISOString().slice(0, 19).replace(/:/g, '-')}${fileExtension}`;
      document.body.appendChild(a);
      a.click();
      window.URL.revokeObjectURL(url);
      document.body.removeChild(a);

      toast?.success('Backup exported successfully');
    } catch (error) {
      console.error('Export failed:', error);
      toast?.error('Failed to export backup');
    } finally {
      setIsExporting(false);
    }
  };

  const handleFileSelect = (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (file) {
      setSelectedFile(file);
    }
  };

  const handleRestore = async () => {
    if (!selectedFile) return;
    setIsRestoring(true);

    try {
      const fileContent = await selectedFile.text();

      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
      };
      if (token) {
        headers['Authorization'] = `Bearer ${token}`;
      }
      const response = await fetch('/api/backup/restore', {
        method: 'POST',
        headers,
        body: JSON.stringify({
          data: fileContent,
          merge: mergeMode,
        }),
      });

      const result = await response.json();

      if (!response.ok) {
        throw new Error(result.error || 'Failed to restore backup');
      }

      toast?.success(result.message || 'Backup restored successfully');
      setSelectedFile(null);
      setMergeMode(false);
      
      // Refresh page after 2 seconds to show updated data
      setTimeout(() => {
        window.location.reload();
      }, 2000);
    } catch (error: any) {
      console.error('Restore failed:', error);
      toast?.error(error.message || 'Failed to restore backup');
    } finally {
      setIsRestoring(false);
    }
  };

  return (
    <div className={styles.container}>
      {/* Export Section */}
      <div className={styles.section}>
        <h2>
          <svg className={styles.icon} fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4" />
          </svg>
          Export Backup
        </h2>
        <p>
          Download a backup of your current configuration to a {fileType} file.
          {!isIngressMode && ' Note: DNS provider credentials are not included for security.'}
        </p>
        <div className={styles.buttonGroup}>
          <button
            className={`${styles.button} ${styles.buttonPrimary}`}
            onClick={handleExport}
            disabled={isExporting}
          >
            {isExporting ? (
              <>
                <svg className={`${styles.icon} ${styles.spinner}`} fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
                </svg>
                Exporting...
              </>
            ) : (
              <>
                <svg className={styles.icon} fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4" />
                </svg>
                Export {isIngressMode ? 'Ingress' : 'Proxy'} Backup
              </>
            )}
          </button>
        </div>
      </div>

      {/* Restore Section */}
      <div className={styles.section}>
        <h2>
          <svg className={styles.icon} fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12" />
          </svg>
          Restore Backup
        </h2>
        <p>
          Upload a previously exported backup file to restore your configuration.
          {!isIngressMode && ' DNS providers will need to be re-added manually with credentials.'}
        </p>

        {!isIngressMode && (
          <div className={`${styles.alert} ${styles.alertWarning}`}>
            <strong>Warning:</strong> Backups include DNS provider credentials, TLS fields, and certificate PEM/key material. Keep backup files secure.
          </div>
        )}

        <input
          type="file"
          id="backup-file"
          accept={fileExtension}
          className={styles.fileInput}
          onChange={handleFileSelect}
        />
        <label htmlFor="backup-file" className={styles.fileLabel}>
          <svg className={styles.icon} fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
          </svg>
          Choose {fileType} Backup File
        </label>

        {selectedFile && (
          <div className={styles.fileName}>
            <svg className={styles.icon} fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
            </svg>
            Selected: <code>{selectedFile.name}</code>
          </div>
        )}

        <div className={styles.checkbox}>
          <input
            type="checkbox"
            id="merge-mode"
            checked={mergeMode}
            onChange={(e) => setMergeMode(e.target.checked)}
          />
          <label htmlFor="merge-mode">
            Merge with existing data (keep current configuration and add from backup)
          </label>
        </div>

        <div className={styles.buttonGroup}>
          <button
            className={`${styles.button} ${styles.buttonPrimary}`}
            onClick={handleRestore}
            disabled={!selectedFile || isRestoring}
          >
            {isRestoring ? (
              <>
                <svg className={`${styles.icon} ${styles.spinner}`} fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
                </svg>
                Restoring...
              </>
            ) : (
              <>
                <svg className={styles.icon} fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12" />
                </svg>
                Restore Backup
              </>
            )}
          </button>
        </div>
      </div>

      {/* Info Section */}
      <div className={styles.section}>
        <h2>About Backups</h2>
        <p>
          <strong>{isIngressMode ? 'Ingress Mode' : 'Proxy Mode'}:</strong>
        </p>
        <ul style={{ marginLeft: '1.5rem', color: 'var(--text-secondary)', lineHeight: '1.8' }}>
          {isIngressMode ? (
            <>
              <li>Backs up all Kubernetes Ingresses and TLS Secrets</li>
              <li>Exports to YAML format compatible with kubectl</li>
              <li>Can be restored to the same or different cluster</li>
              <li>Merge mode allows adding resources without replacing existing ones</li>
            </>
          ) : (
            <>
              <li>Backs up sites configuration, backends, and routing rules</li>
              <li>Includes TLS certificate PEM and private key text</li>
              <li>Includes DNS provider credentials and provider settings</li>
              <li>Exports to JSON format for easy inspection and editing</li>
              <li>Merge mode allows adding sites without replacing existing configuration</li>
            </>
          )}
        </ul>
      </div>
    </div>
  );
}
