import '../models/auth.dart' show LoginProvider;

// Port of OpenNOW auth/constants.ts — exact values, do not change.
const serviceUrlsEndpoint = 'https://pcs.geforcenow.com/v1/serviceUrls';
const tokenEndpoint = 'https://login.nvidia.com/token';
const clientTokenEndpoint = 'https://login.nvidia.com/client_token';
const userinfoEndpoint = 'https://login.nvidia.com/userinfo';
const authEndpoint = 'https://login.nvidia.com/authorize';
const deviceAuthorizeEndpoint = 'https://login.nvidia.com/device/authorize';

const clientId = 'ZU7sPN-miLujMD95LfOQ453IB0AtjM8sMyvgJ9wCXEQ';
const steamDeckClientId = 'q61ddeJrVt7O90Nl-P-N7I36yctih4Ml6FyXLrb6j-U';
const scopes = 'openid consent email tk_client age';
const defaultIdpId = 'PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg';
const steamDeckUserAgent =
    'Mozilla/5.0 (X11; Linux x86_64; Steam Deck) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

const redirectPorts = [2259, 6460, 7119, 8870, 9096];
const tokenRefreshWindowMs = 10 * 60 * 1000;
const clientTokenRefreshWindowMs = 5 * 60 * 1000;

// Port of auth/providerDiscovery.ts defaultProvider
LoginProvider defaultProvider() => const LoginProvider(
      idpId: defaultIdpId,
      code: 'NVIDIA',
      displayName: 'NVIDIA',
      streamingServiceUrl: 'https://prod.cloudmatchbeta.nvidiagrid.net/',
      priority: 0,
    );