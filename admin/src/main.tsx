import React, { useEffect, useState } from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { ThemeProvider } from '@/context/ThemeContext';
import { ToastProvider } from '@/context/ToastContext';
import { api } from '@/api/client';
import { isLoggedIn, setToken, setUsername } from '@/auth';
import App from './App';
import Toaster from '@/components/Toaster';
import './index.css';
import './styles/theme.css';

function GuestBootstrap({ children }: { children: React.ReactNode }) {
  const [ready, setReady] = useState(false);
  useEffect(() => {
    let cancelled = false;
    api
      .authConfig()
      .then((c) => {
        if (cancelled) return;
        if (c.guest_mode && !isLoggedIn()) {
          setToken('guest', 60 * 60 * 24 * 365);
          setUsername('operator');
        }
        setReady(true);
      })
      .catch(() => {
        if (!cancelled) setReady(true);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  if (!ready) {
    return (
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100vh' }}>
        <div className="spinner" />
      </div>
    );
  }
  return <>{children}</>;
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <ThemeProvider>
      <ToastProvider>
        <BrowserRouter>
          <GuestBootstrap>
            <App />
          </GuestBootstrap>
          <Toaster />
        </BrowserRouter>
      </ToastProvider>
    </ThemeProvider>
  </React.StrictMode>,
);
