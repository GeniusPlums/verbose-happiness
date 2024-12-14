import convict from 'convict';

export const API_BASE_URL_KEY = 'apiBaseUrl';
export const WS_BASE_URL_KEY = 'wsBaseUrl';
export const ONBOARDING_API_KEY_KEY = 'onboardingApiKey';

const config = convict({
  [API_BASE_URL_KEY]: {
    doc: 'The base URL for API requests',
    format: String,
    default: 'http://localhost:3001',
    env: 'REACT_APP_API_BASE_URL'
  },
  [WS_BASE_URL_KEY]: {
    doc: 'The base URL for WebSocket connections',
    format: String,
    default: 'ws://localhost:3001',
    env: 'REACT_APP_WS_BASE_URL'
  },
  [ONBOARDING_API_KEY_KEY]: {
    doc: 'API key for onboarding',
    format: String,
    default: '',
    env: 'REACT_APP_ONBOARDING_API_KEY'
  }
});

// Perform validation
config.validate({allowed: 'strict'});

export default config;
