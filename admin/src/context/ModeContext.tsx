import { createContext, useContext } from 'react';

/** `proxy` = reverse proxy with embedded admin SPA on :9080; `ingress` = K8s controller (Sites via Ingress CRUD). */
export type ApiMode = 'proxy' | 'ingress';

const ModeContext = createContext<ApiMode | undefined>(undefined);

export function useMode(): ApiMode | undefined {
  return useContext(ModeContext);
}

/** True when mode is known and is ingress. When undefined (not yet loaded), false so we don't call DNS API until we know. */
export function useIsIngressMode(): boolean {
  return useMode() === 'ingress';
}

/** True when mode is known and is proxy (DNS providers API available). */
export function useIsProxyMode(): boolean {
  const m = useMode();
  return m === 'proxy';
}

export { ModeContext };
