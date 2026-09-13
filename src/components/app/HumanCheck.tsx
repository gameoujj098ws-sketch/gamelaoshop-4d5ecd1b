import { useState } from "react";
import { Check, Loader2, ShieldCheck } from "lucide-react";

/**
 * Lightweight "I'm not a robot" checkbox used below the login / register
 * buttons. Pure client-side friction against naive bots.
 */
export function HumanCheck({
  verified,
  onVerified,
}: {
  verified: boolean;
  onVerified: (v: boolean) => void;
}) {
  const [busy, setBusy] = useState(false);

  const run = () => {
    if (busy || verified) return;
    setBusy(true);
    window.setTimeout(() => {
      setBusy(false);
      onVerified(true);
    }, 900);
  };

  return (
    <div className="rounded-2xl border bg-muted/40 p-3 flex items-center gap-3">
      <button
        type="button"
        onClick={run}
        aria-label="ຢືນຢັນວ່າບໍ່ແມ່ນບອດ"
        className={`h-7 w-7 rounded-md border-2 flex items-center justify-center shrink-0 transition ${
          verified ? "border-[color:var(--color-success,theme(colors.primary))] bg-primary text-primary-foreground" : "border-muted-foreground/40 bg-background"
        }`}
      >
        {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : verified ? <Check className="h-4 w-4" strokeWidth={3} /> : null}
      </button>
      <span className="text-sm font-medium flex-1">
        {verified ? "ຢືນຢັນແລ້ວ ວ່າບໍ່ແມ່ນບອດ" : busy ? "ກຳລັງກວດສອບ..." : "ຂ້ອຍບໍ່ແມ່ນບອດ"}
      </span>
      <ShieldCheck className="h-5 w-5 text-primary shrink-0" />
    </div>
  );
}
