// SIWA by Regents: types for siwa-site.mjs, a site's check, for a TypeScript server.
//
// Keep this file beside siwa-site.mjs and import `checkAgent` from it as usual.
// Guide: https://siwa.regents.sh/websites.md

/** SIWA's answer about the agent that signed a request. Other fields describe the signature. */
export interface Agent {
  /** The caller ID: `eip155:<chain id>:<address>`, in lowercase. Store this. */
  subject: string;
  /** The agent's address, in lowercase. */
  walletAddress: `0x${string}`;
  /** The chain the agent signed in on: `8453` for Base, `1` for Ethereum. */
  chainId: 1 | 8453;
  /** `eoa_recovery` for an ordinary key; `erc1271` or `erc6492` for a smart wallet. */
  verificationMethod: "eoa_recovery" | "erc1271" | "erc6492";
  /** The agent's listing in the public ERC-8004 agent registry on Base, or `null`. */
  agentRegistration: {
    agentId: string;
    /** A page you can link to. */
    registryUrl: string;
    /** The listing's own profile, or `null`. */
    profileUrl: string | null;
  } | null;
  /** The person who vouched for the agent with World ID, or `null`. */
  agentBook: {
    /** That person's anonymous number. */
    humanId: string;
    /** How many agents have accepted the same person. */
    agentCount: number;
  } | null;
  /** Production sites only. */
  usage?: {
    /** `true` on the agent's first check this billing period, the one that counts toward your bill, and `false` every time after. */
    newThisPeriod: boolean;
  };
}

/** A refusal, ready to send back to the agent as it is. */
export interface Refusal {
  /** `401` when the agent's own request is at fault; `503` for your site's trouble or SIWA's. */
  status: 401 | 503;
  /** `signature_required`, SIWA's own code for the agent's request, or `service_unavailable`. */
  code: string;
  /** A sentence for the agent. */
  message: string;
  /** SIWA's `retry-after` to pass on, or `null`. */
  retryAfter: string | null;
}

/**
 * Asks SIWA whether an agent signed this exact request for your site.
 *
 * Resolves to `{ agent }`, SIWA's answer about the agent, or to `{ refusal }`. `key` is
 * the site's server key (`SIWA_SERVER_KEY` unless given); `host` is the public host
 * agents send to, for a server behind a proxy.
 */
export function checkAgent(
  request: Request,
  options?: { key?: string | undefined; host?: string | undefined },
): Promise<{ agent: Agent; refusal?: undefined } | { agent?: undefined; refusal: Refusal }>;
