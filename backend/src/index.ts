import { sweepInboundCalls } from "./call-settle";
import { sweepHunts } from "./hunt";
import { startLanes } from "./lanes";
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
    if (controller.cron === "* * * * *") {
      // Every minute: reminders, the 08:00 text and the 09:00 price check. Nothing else runs here.
      ctx.waitUntil(
        import("./sms-extras")
          .then(async (m) => {
            await m.fireDueReminders(env).catch((err) => console.error("reminders", err instanceof Error ? err.message : err));
            await m.sweepMorningText(env).catch((err) => console.error("morning", err instanceof Error ? err.message : err));
            await m.sweepPriceWatches(env).catch((err) => console.error("watches", err instanceof Error ? err.message : err));
          })
          .catch(() => null),
      );
      return;
    }
    ctx.waitUntil(
      Promise.all([
        startLanes(env, `cron:${controller.cron}`),
        (async () => {
          await runMissionTick(env);
          await runPersonaTick(env);
        })(),
        sweepOwner(env),
        sweepMemoryNudges(env),
        sweepHunts(env),
        sweepInboundCalls(env),
        import("./voice-notes").then((m) => m.sweepVoiceNotes(env)).catch(() => null),
        import("./desk")
          .then(async (m) => {
            const { readCallSettings } = await import("./owner-alert");
            const origin = ((await readCallSettings(env)).worker_origin ?? "").replace(/^http:/, "https:");
            return origin ? m.ensureDeskAgent(env, origin) : null;
          })
          .catch(() => null),
        import("./briefing-call").then((m) => m.sweepBriefingCall(env)).catch(() => "error"),
      ]),
    );
  },
};
