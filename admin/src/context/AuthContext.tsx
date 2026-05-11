import { createContext, useContext } from 'react';

export type AuthContextValue = {
  openPasswordModal: () => void;
};

const AuthContext = createContext<AuthContextValue | null>(null);

export function useAuth() {
  const ctx = useContext(AuthContext);
  return ctx;
}

export const AuthProvider = AuthContext.Provider;
