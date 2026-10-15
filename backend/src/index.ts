import { runTick } from "./execute";
import { runPersonaTick } from "./personas";
import { route } from "./routes";
import type { Env } from "./types";

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    return route(request, env, ctx);
  },
  async scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(Promise.all([runTick(env, `cron:${controller.cron}`), runPersonaTick(env)]));
  },
};
