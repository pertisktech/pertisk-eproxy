import { createContext, useContext } from 'react';

/** `proxy` = reverse-proxy only; `proxy_admin` = same + embedded admin SPA on :9080; `ingress` = viewer-only. */
export type ApiMode = 'proxy' | 'proxy_admin' | 'ingress';

const ModeContext = createContext<ApiMode | undefined>(undefined);

export function useMode(): ApiMode | undefined {
  return useContext(ModeContext);
}

/** True when mode is known and is ingress. When undefined (not yet loaded), false so we don't call DNS API until we know. */
export function useIsIngressMode(): boolean {
  return useMode() === 'ingress';
}

/** True when mode is known and is proxy or proxy_admin (DNS providers API available). */
export function useIsProxyMode(): boolean {
  const m = useMode();
  return m === 'proxy' || m === 'proxy_admin';
}

export { ModeContext };
