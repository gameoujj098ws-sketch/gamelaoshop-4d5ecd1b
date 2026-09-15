import { useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";

const LAST_SEEN = "session_last_seen_v1";
/** Sessions stay alive across browser restarts for up to 3 days of inactivity. */
const MAX_IDLE_MS = 3 * 24 * 60 * 60 * 1000;

/**
 * Keeps the login session alive (auto refresh handled by the auth client) but
 * forces a fresh sign-in once the account has been idle for too long.
 */
export function SessionGuard() {
  useEffect(() => {
    const touch = () => {
      try {
        localStorage.setItem(LAST_SEEN, String(Date.now()));
      } catch {
        /* ignore */
      }
    };

    const check = async () => {
      let last = 0;
      try {
        last = Number(localStorage.getItem(LAST_SEEN) || 0);
      } catch {
        last = 0;
      }
      const { data } = await supabase.auth.getSession();
      if (!data.session) return;
      if (last && Date.now() - last > MAX_IDLE_MS) {
        await supabase.auth.signOut();
        try {
          localStorage.removeItem(LAST_SEEN);
        } catch {
          /* ignore */
        }
        return;
      }
      touch();
    };

    check();
    const events: Array<keyof WindowEventMap> = ["click", "keydown", "visibilitychange"];
    events.forEach((e) => window.addEventListener(e, touch));
    const timer = window.setInterval(check, 5 * 60 * 1000);
    return () => {
      events.forEach((e) => window.removeEventListener(e, touch));
      window.clearInterval(timer);
    };
  }, []);

  return null;
}
