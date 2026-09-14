import { useCallback } from "react";
import { ShieldCheck } from "lucide-react";
import { Recaptcha } from "./Recaptcha";

/**
 * Real Google reCAPTCHA v2 verification shown below the login / register
 * buttons.
 */
export function HumanCheck({
  verified,
  onVerified,
}: {
  verified: boolean;
  onVerified: (v: boolean) => void;
}) {
  const handle = useCallback((ok: boolean) => onVerified(ok), [onVerified]);

  return (
    <div className="rounded-2xl border bg-muted/40 p-3 space-y-2">
      <Recaptcha onVerified={handle} />
      {verified && (
        <div className="flex items-center gap-2 text-sm font-medium text-primary">
          <ShieldCheck className="h-4 w-4" /> ຢືນຢັນແລ້ວ ວ່າບໍ່ແມ່ນບອດ
        </div>
      )}
    </div>
  );
}
