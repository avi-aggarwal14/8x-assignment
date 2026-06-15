import type { RateLimitResult } from './types';

type Entry = { count: number; windowStart: number };

export function createRateLimiter(maxAttempts: number, windowMs: number) {
  const store = new Map<string, Entry>();

  function check(key: string): RateLimitResult {
    const now = Date.now();
    const entry = store.get(key);

    if (!entry || now - entry.windowStart >= windowMs) {
      // A limit below 1 must block even the first attempt — otherwise the
      // window-seeding path admits one request past the cap (the N+1 bug at
      // the N=0 boundary).
      if (maxAttempts < 1) {
        return { allowed: false, retryAfterMs: windowMs };
      }
      store.set(key, { count: 1, windowStart: now });
      return { allowed: true };
    }

    if (entry.count < maxAttempts) {
      entry.count++;
      return { allowed: true };
    }

    const retryAfterMs = windowMs - (now - entry.windowStart);
    return { allowed: false, retryAfterMs };
  }

  function reset(key: string): void {
    store.delete(key);
  }

  return { check, reset };
}
