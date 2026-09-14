import { useEffect, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { getRecaptchaSiteKey, verifyRecaptchaToken } from "@/lib/recaptcha.functions";

declare global {
  interface Window {
    grecaptcha?: {
      render: (el: HTMLElement, opts: Record<string, unknown>) => number;
      reset: (id?: number) => void;
    };
    __recaptchaOnLoad?: () => void;
  }
}

let scriptPromise: Promise<void> | null = null;

function loadRecaptchaScript() {
  if (scriptPromise) return scriptPromise;
  scriptPromise = new Promise<void>((resolve, reject) => {
    if (window.grecaptcha?.render) return resolve();
    window.__recaptchaOnLoad = () => resolve();
    const s = document.createElement("script");
    s.src = "https://www.google.com/recaptcha/api.js?onload=__recaptchaOnLoad&render=explicit&hl=lo";
    s.async = true;
    s.defer = true;
    s.onerror = () => reject(new Error("recaptcha_script_error"));
    document.head.appendChild(s);
  });
  return scriptPromise;
}

/**
 * Real Google reCAPTCHA v2 checkbox. Calls onVerified(true) only after the
 * token is validated on the server with the secret key.
 */
export function Recaptcha({
  onVerified,
  theme = "light",
}: {
  onVerified: (ok: boolean) => void;
  theme?: "light" | "dark";
}) {
  const boxRef = useRef<HTMLDivElement>(null);
  const widgetId = useRef<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const siteKeyFn = useServerFn(getRecaptchaSiteKey);
  const verifyFn = useServerFn(verifyRecaptchaToken);

  const { data } = useQuery({
    queryKey: ["recaptcha-site-key"],
    queryFn: () => siteKeyFn(),
    staleTime: 5 * 60 * 1000,
  });

  const siteKey = data?.siteKey ?? "";
  const configured = !!data?.configured;

  useEffect(() => {
    if (!configured || !siteKey || !boxRef.current || widgetId.current !== null) return;
    let cancelled = false;
    loadRecaptchaScript()
      .then(() => {
        if (cancelled || !boxRef.current || !window.grecaptcha || widgetId.current !== null) return;
        widgetId.current = window.grecaptcha.render(boxRef.current, {
          sitekey: siteKey,
          theme,
          callback: async (token: string) => {
            const res = await verifyFn({ data: { token } });
            if (res.ok) {
              setError(null);
              onVerified(true);
            } else {
              setError("ການຢືນຢັນລົ້ມເຫຼວ ກະລຸນາລອງໃໝ່");
              onVerified(false);
              window.grecaptcha?.reset(widgetId.current ?? undefined);
            }
          },
          "expired-callback": () => onVerified(false),
          "error-callback": () => {
            setError("ບໍ່ສາມາດໂຫຼດ reCAPTCHA");
            onVerified(false);
          },
        });
      })
      .catch(() => setError("ບໍ່ສາມາດໂຫຼດ reCAPTCHA"));
    return () => {
      cancelled = true;
    };
  }, [configured, siteKey, theme, onVerified, verifyFn]);

  // Keys not configured yet: don't block the user.
  useEffect(() => {
    if (data && !configured) onVerified(true);
  }, [data, configured, onVerified]);

  if (data && !configured) return null;

  return (
    <div className="space-y-2">
      <div ref={boxRef} />
      {error && <p className="text-xs text-destructive">{error}</p>}
    </div>
  );
}
