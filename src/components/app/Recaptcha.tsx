import { useEffect, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { getRecaptchaSiteKey, verifyRecaptchaToken } from "@/lib/recaptcha.functions";

declare global {
  interface Window {
    grecaptcha?: {
      render: (el: HTMLElement, opts: Record<string, unknown>) => number;
      reset: (id?: number) => void;
      remove?: (id: number) => void;
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
    s.onerror = () => {
      scriptPromise = null;
      reject(new Error("recaptcha_script_error"));
    };
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
  const mounted = useRef(true);
  const verified = useRef(false);
  const verifyingToken = useRef<string | null>(null);
  const onVerifiedRef = useRef(onVerified);
  const verifyFnRef = useRef<ReturnType<typeof useServerFn>>(undefined);
  const [error, setError] = useState<string | null>(null);
  const siteKeyFn = useServerFn(getRecaptchaSiteKey);
  const verifyFn = useServerFn(verifyRecaptchaToken);

  onVerifiedRef.current = onVerified;
  verifyFnRef.current = verifyFn;

  const { data } = useQuery({
    queryKey: ["recaptcha-site-key"],
    queryFn: () => siteKeyFn(),
    staleTime: 5 * 60 * 1000,
  });

  const siteKey = data?.siteKey ?? "";
  const configured = !!data?.configured;

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

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
            if (verified.current || verifyingToken.current === token) return;
            verifyingToken.current = token;
            setError(null);

            try {
              const verify = verifyFnRef.current;
              if (!verify) throw new Error("verification_unavailable");
              const res = await verify({ data: { token } });
              if (!mounted.current) return;

              if (res.ok) {
                verified.current = true;
                setError(null);
                onVerifiedRef.current(true);
                return;
              }

              const retryable = res.reason === "network_error" || res.reason === "internal_error";
              setError(
                retryable
                  ? "ການເຊື່ອມຕໍ່ Google ຂັດຂ້ອງ ກະລຸນາກົດຢືນຢັນອີກຄັ້ງ"
                  : "Google ບໍ່ສາມາດຢືນຢັນໄດ້ ກະລຸນາກົດຢືນຢັນອີກຄັ້ງ",
              );
              onVerifiedRef.current(false);
              window.grecaptcha?.reset(widgetId.current ?? undefined);
            } catch {
              if (!mounted.current) return;
              setError("ການເຊື່ອມຕໍ່ Google ຂັດຂ້ອງ ກະລຸນາກົດຢືນຢັນອີກຄັ້ງ");
              onVerifiedRef.current(false);
              window.grecaptcha?.reset(widgetId.current ?? undefined);
            } finally {
              verifyingToken.current = null;
            }
          },
          "expired-callback": () => {
            verified.current = false;
            verifyingToken.current = null;
            onVerifiedRef.current(false);
          },
          "error-callback": () => {
            setError("ບໍ່ສາມາດໂຫຼດ reCAPTCHA");
            verified.current = false;
            verifyingToken.current = null;
            onVerifiedRef.current(false);
          },
        });
      })
      .catch(() => setError("ບໍ່ສາມາດໂຫຼດ reCAPTCHA"));
    return () => {
      cancelled = true;
    };
  }, [configured, siteKey, theme]);

  // Keys not configured yet: don't block the user.
  useEffect(() => {
    if (data && !configured) onVerifiedRef.current(true);
  }, [data, configured]);

  if (data && !configured) return null;

  return (
    <div className="space-y-2">
      <div ref={boxRef} />
      {error && <p className="text-xs text-destructive">{error}</p>}
    </div>
  );
}
