import { createServerFn } from "@tanstack/react-start";

/** Public site key for Google reCAPTCHA v2 ("I'm not a robot" checkbox). */
export const getRecaptchaSiteKey = createServerFn({ method: "GET" }).handler(async () => {
  const siteKey = process.env["RECAPTCHA_SITE_KEY"] ?? "";
  const configured = !!siteKey && !!process.env["RECAPTCHA_SECRET_KEY"];
  return { siteKey, configured };
});

/** Verifies a reCAPTCHA token against Google's siteverify endpoint. */
export const verifyRecaptchaToken = createServerFn({ method: "POST" })
  .inputValidator((data: { token: string }) => ({ token: String(data?.token ?? "") }))
  .handler(async ({ data }) => {
    const secret = process.env["RECAPTCHA_SECRET_KEY"];
    if (!secret) return { ok: false, reason: "not_configured" as const };
    if (!data.token) return { ok: false, reason: "missing_token" as const };

    try {
      const res = await fetch("https://www.google.com/recaptcha/api/siteverify", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ secret, response: data.token }).toString(),
      });
      if (!res.ok) return { ok: false as const, reason: "network_error" };

      const json = (await res.json()) as { success?: boolean; "error-codes"?: string[] };
      if (json.success) return { ok: true as const };
      const reason = (json["error-codes"] ?? ["failed"])[0] ?? "failed";
      console.warn("reCAPTCHA verification rejected:", reason);
      return { ok: false as const, reason };
    } catch {
      return { ok: false as const, reason: "internal_error" };
    }
  });
