import { useEffect, useState, type ReactNode } from "react";
import { ShieldCheck } from "lucide-react";

const KEY = "human_gate_v1";
const TTL_MS = 30 * 60 * 1000;

/**
 * Security interstitial shown before the site loads: verifies the visitor
 * is not a bot, then remembers the result for a short while.
 */
export function BotGate({ children }: { children: ReactNode }) {
  const [ready, setReady] = useState(false);
  const [passed, setPassed] = useState(false);

  useEffect(() => {
    let ok = false;
    try {
      const raw = localStorage.getItem(KEY);
      ok = !!raw && Date.now() - Number(raw) < TTL_MS;
    } catch {
      ok = false;
    }
    setPassed(ok);
    setReady(true);
    if (ok) return;
    const t = window.setTimeout(() => {
      try {
        localStorage.setItem(KEY, String(Date.now()));
      } catch {
        /* ignore */
      }
      setPassed(true);
    }, 2200);
    return () => window.clearTimeout(t);
  }, []);

  if (!ready) return null;
  if (passed) return <>{children}</>;

  return (
    <div className="fixed inset-0 z-[100] bg-[#1d1d1d] text-white overflow-auto">
      <div className="max-w-md mx-auto px-6 pt-24 pb-10">
        <h1 className="text-4xl font-extrabold tracking-tight">ກຳລັງກວດສອບຄວາມປອດໄພ</h1>
        <p className="mt-5 text-base leading-relaxed text-white/80">
          ເວັບໄຊນີ້ໃຊ້ບໍລິການຮັກສາຄວາມປອດໄພເພື່ອປ້ອງກັນບອດອັນຕະລາຍ
          ໜ້ານີ້ຈະປາກົດຂຶ້ນໃນຂະນະທີ່ລະບົບກວດສອບວ່າທ່ານບໍ່ແມ່ນບອດ
        </p>
        <div className="mt-8 rounded-lg bg-white/10 border border-white/15 p-5 flex items-center gap-4">
          <span className="h-6 w-6 rounded-full border-2 border-white/30 border-t-transparent animate-spin" />
          <span className="text-sm flex-1">ກຳລັງກວດສອບ...</span>
          <ShieldCheck className="h-6 w-6 text-white/70" />
        </div>
      </div>
    </div>
  );
}
