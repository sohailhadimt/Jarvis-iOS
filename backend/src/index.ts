import { runTick } from "./execute";
import { sweepHunts } from "./hunt";
import { runMissionTick } from "./missions";
import { sweepOwner } from "./owner-alert";
import { runPersonaTick } from "./personas";
import { route } from "./routes";
import { sweepMemoryNudges } from "./sms-desk";
import type { Env } from "./types";

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    return route(request, env, ctx);
  },
  async scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(
      Promise.all([
        runTick(env, `cron:${controller.cron}`),
        (async () => {
          await runMissionTick(env);
          await runPersonaTick(env);
        })(),
        sweepOwner(env),
        sweepMemoryNudges(env),
        sweepHunts(env),
      ]),
    );
  },
};
