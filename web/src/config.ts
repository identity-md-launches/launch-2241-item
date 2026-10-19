// Chain facts from .imd/reads/network.json and the token's decimals from .imd/reads/deployment.json.
// The token address, name, symbol and every logo file come from assets/logo/logo.json.
export const CHAIN = {
  id: 4663,
  name: "Robinhood Chain",
  explorer: "https://robin.etherscan.io",
} as const;

export const TOKEN_DECIMALS = 18;
