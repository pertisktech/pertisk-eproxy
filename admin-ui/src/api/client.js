import axios from 'axios';

// Use relative path so API calls go through the same origin as the UI.
// Falls back to env override for local dev without the proxy.
const API_BASE_URL = process.env.REACT_APP_API_URL || '/api';

const api = axios.create({
  baseURL: API_BASE_URL,
  headers: {
    'Content-Type': 'application/json',
  },
});

// Status endpoints
export const getStatus = async () => {
  try {
    const response = await api.get('/status');
    return response.data;
  } catch (error) {
    console.error('Failed to get status:', error);
    throw error;
  }
};

// Upstream management endpoints
export const getUpstreams = async () => {
  try {
    const response = await api.get('/upstreams');
    return response.data.upstreams || [];
  } catch (error) {
    console.error('Failed to get upstreams:', error);
    throw error;
  }
};

export const addUpstream = async (upstream) => {
  try {
    const response = await api.post('/upstreams', {
      name: upstream.name,
      target: upstream.target,
      health_check: upstream.health_check,
      weight: upstream.weight || 1,
    });
    return response.data;
  } catch (error) {
    console.error('Failed to add upstream:', error);
    throw error;
  }
};

export const removeUpstream = async (host) => {
  try {
    const response = await api.delete(`/upstreams/${host}`);
    return response.data;
  } catch (error) {
    console.error('Failed to remove upstream:', error);
    throw error;
  }
};

// Certificate endpoints
export const getCertificates = async () => {
  try {
    const response = await api.get('/certs');
    return response.data;
  } catch (error) {
    console.error('Failed to get certificates:', error);
    throw error;
  }
};

export const requestCertificate = async (domains) => {
  try {
    const response = await api.post('/certs/request', {
      domains,
    });
    return response.data;
  } catch (error) {
    console.error('Failed to request certificate:', error);
    throw error;
  }
};

export default api;
