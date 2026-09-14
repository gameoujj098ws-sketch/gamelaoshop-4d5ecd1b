import { useCallback, useEffect, useState, type ReactNode } from "react";
import { ShieldCheck } from "lucide-react";
import { Recaptcha } from "./Recaptcha";

const KEY = "human_gate_v1";
const TTL_MS = 30 * 60 * 1000;

/**
 * Security interstitial shown before the site loads: the visitor must pass a
 * real Google reCAPTCHA, then the result is remembered for a short while.
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
  }, []);

  const pass = useCallback((ok: boolean) => {
    if (!ok) return;
    try {
      localStorage.setItem(KEY, String(Date.now()));
    } catch {
      /* ignore */
    }
    setPassed(true);
  }, []);

  if (!ready) return null;
  if (passed) return <>{children}</>;

  return (
    <div className="fixed inset-0 z-[100] bg-[#1d1d1d] text-white overflow-auto">
      <div className="max-w-md mx-auto px-6 pt-24 pb-10">
        <h1 className="text-4xl font-extrabold tracking-tight">ກຳລັງກວດສອບຄວາມປອດໄພ</h1>
        <p className="mt-5 text-base leading-relaxed text-white/80">
          ເວັບໄຊນີ້ໃຊ້ບໍລິການຮັກສາຄວາມປອດໄພເພື່ອປ້ອງກັນບອດອັນຕະລາຍ
          ກະລຸນາຢືນຢັນວ່າທ່ານບໍ່ແມ່ນບອດເພື່ອເຂົ້າສູ່ເວັບໄຊ
        </p>
        <div className="mt-8 rounded-lg bg-white/10 border border-white/15 p-5 flex items-center gap-4">
          <div className="flex-1">
            <Recaptcha onVerified={pass} theme="dark" />
          </div>
          <ShieldCheck className="h-6 w-6 text-white/70 shrink-0" />
        </div>
      </div>
    </div>
  );
}
