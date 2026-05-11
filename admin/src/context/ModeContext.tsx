import { createContext, useContext } from 'react';

/** "proxy" = full management with DB; "ingress" = viewer-only, no DNS providers. */
export type ApiMode = 'proxy' | 'ingress';

const ModeContext = createContext<ApiMode | undefined>(undefined);

export function useMode(): ApiMode | undefined {
  return useContext(ModeContext);
}

/** True when mode is known and is ingress. When undefined (not yet loaded), false so we don't call DNS API until we know. */
export function useIsIngressMode(): boolean {
  return useMode() === 'ingress';
}

/** True when mode is known and is proxy (so DNS providers API is available). */
export function useIsProxyMode(): boolean {
  return useMode() === 'proxy';
}

export { ModeContext };
