export interface CronExpr {
  minute: Set<number>;
  hour: Set<number>;
  dom: Set<number>;
  month: Set<number>;
  dow: Set<number>;
  raw: string;
}

const DOM_SPAN = 31;
const DOW_SPAN = 7;

export function parseCron(input: string): CronExpr | null {
  const parts = input.trim().split(/\s+/);
  if (parts.length !== 5) return null;
  const minute = parseField(parts[0], 0, 59);
  const hour = parseField(parts[1], 0, 23);
  const dom = parseField(parts[2], 1, 31);
  const month = parseField(parts[3], 1, 12);
  const dow = parseField(parts[4], 0, 7);
  if (!minute || !hour || !dom || !month || !dow) return null;
  if (dow.has(7)) {
    dow.delete(7);
    dow.add(0);
  }
  return { minute, hour, dom, month, dow, raw: input.trim() };
}

function parseField(field: string, min: number, max: number): Set<number> | null {
  if (!field || field.length > 80) return null;
  const set = new Set<number>();
  for (const piece of field.split(",")) {
    if (!piece) return null;
    const stepSplit = piece.split("/");
    if (stepSplit.length > 2) return null;
    const step = stepSplit.length === 2 ? Number(stepSplit[1]) : 1;
    if (!Number.isInteger(step) || step <= 0) return null;
    const range = stepSplit[0];
    let start = min;
    let end = max;
    if (range === "*") {
      start = min;
      end = max;
    } else if (range.includes("-")) {
      const bits = range.split("-");
      if (bits.length !== 2) return null;
      start = Number(bits[0]);
      end = Number(bits[1]);
      if (!Number.isInteger(start) || !Number.isInteger(end)) return null;
      if (start < min || end > max || start > end) return null;
    } else {
      start = Number(range);
      if (!Number.isInteger(start) || start < min || start > max) return null;
      end = stepSplit.length === 2 ? max : start;
    }
    for (let value = start; value <= end; value += step) set.add(value);
  }
  return set.size === 0 ? null : set;
}

export function cronMatches(date: Date, expr: CronExpr): boolean {
  if (!expr.minute.has(date.getUTCMinutes())) return false;
  if (!expr.hour.has(date.getUTCHours())) return false;
  if (!expr.month.has(date.getUTCMonth() + 1)) return false;
  const domStar = expr.dom.size === DOM_SPAN;
  const dowStar = expr.dow.size === DOW_SPAN;
  const domOk = expr.dom.has(date.getUTCDate());
  const dowOk = expr.dow.has(date.getUTCDay());
  if (domStar && dowStar) return true;
  if (domStar) return dowOk;
  if (dowStar) return domOk;
  return domOk || dowOk;
}

/** Next UTC minute this expression matches, strictly after `from`. */
export function computeNextRun(from: Date, expr: CronExpr): string | null {
  let cursor = Date.UTC(
    from.getUTCFullYear(),
    from.getUTCMonth(),
    from.getUTCDate(),
    from.getUTCHours(),
    from.getUTCMinutes(),
    0,
    0,
  );
  cursor += 60_000;
  const limit = from.getTime() + 370 * 24 * 60 * 60 * 1000;
  for (let guard = 0; guard < 20_000 && cursor <= limit; guard++) {
    const date = new Date(cursor);
    const month = date.getUTCMonth() + 1;
    if (!expr.month.has(month)) {
      cursor = Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 1, 0, 0, 0, 0);
      continue;
    }
    if (!expr.hour.has(date.getUTCHours())) {
      cursor = Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate(), date.getUTCHours() + 1, 0, 0, 0);
      continue;
    }
    if (!expr.minute.has(date.getUTCMinutes())) {
      const later = [...expr.minute].sort((a, b) => a - b).find((minute) => minute > date.getUTCMinutes());
      cursor =
        later === undefined
          ? Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate(), date.getUTCHours() + 1, 0, 0, 0)
          : Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate(), date.getUTCHours(), later, 0, 0);
      continue;
    }
    if (cronMatches(date, expr)) return new Date(cursor).toISOString();
    cursor = Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate() + 1, 0, 0, 0, 0);
  }
  return null;
}
