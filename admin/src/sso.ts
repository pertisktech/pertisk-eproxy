import { createAuth0Client, type Auth0Client } from '@auth0/auth0-spa-js';

export type Auth0ClientConfig = {
  domain: string;
  clientId: string;
  audience?: string;
};

let clientPromise: Promise<Auth0Client> | null = null;
let cachedKey: string | null = null;

export function getAuth0Client(config: Auth0ClientConfig): Promise<Auth0Client> {
  const key = `${config.domain}::${config.clientId}::${config.audience || ''}`;
  if (!clientPromise || cachedKey !== key) {
    cachedKey = key;
    clientPromise = createAuth0Client({
      domain: config.domain,
      clientId: config.clientId,
      authorizationParams: {
        ...(config.audience ? { audience: config.audience } : {}),
        redirect_uri: `${window.location.origin}/login`,
      },
      cacheLocation: 'memory',
      useRefreshTokens: false,
    });
  }
  return clientPromise as Promise<Auth0Client>;
}
