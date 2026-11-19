// The websites guide's Trial and Wallet code, typechecked against siwa-site.d.mts: once a
// refusal is returned, `agent` is an Agent.
import { checkAgent } from "../priv/static/site/siwa-site.mjs";

export async function startTrial(request: Request): Promise<Response> {
  const { agent, refusal } = await checkAgent(request);

  if (refusal) return Response.json({ error: refusal }, { status: refusal.status });

  const subject: string = agent.subject;
  const humanId: string | undefined = agent.agentBook?.humanId;
  const wallet: { walletAddress: `0x${string}`; chainId: number } = agent;

  return Response.json({ subject, humanId, address: wallet.walletAddress }, { status: 201 });
}
