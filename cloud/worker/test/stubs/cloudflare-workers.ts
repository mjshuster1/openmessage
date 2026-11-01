// Minimal stand-in for the `cloudflare:workers` module (Node tests only).
export class WorkerEntrypoint<Env = unknown> {
  ctx: unknown;
  env: Env;
  constructor(ctx: unknown, env: Env) {
    this.ctx = ctx;
    this.env = env;
  }
}
export class DurableObject {}
export class RpcTarget {}
export const env = {};
