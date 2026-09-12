
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS banned boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS ban_reason text,
  ADD COLUMN IF NOT EXISTS banned_at timestamptz;

CREATE OR REPLACE FUNCTION public.admin_set_ban(_user_id uuid, _banned boolean, _reason text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'not_admin';
  END IF;
  UPDATE public.profiles
     SET banned = _banned,
         ban_reason = CASE WHEN _banned THEN _reason ELSE NULL END,
         banned_at = CASE WHEN _banned THEN now() ELSE NULL END
   WHERE id = _user_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_user_summary(_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  res jsonb;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'not_admin';
  END IF;
  SELECT jsonb_build_object(
    'profile', (SELECT to_jsonb(p) FROM public.profiles p WHERE p.id = _user_id),
    'topup_count', (SELECT count(*) FROM public.topups t WHERE t.user_id = _user_id AND t.status = 'approved'),
    'topup_total', (SELECT COALESCE(sum(t.amount),0) FROM public.topups t WHERE t.user_id = _user_id AND t.status = 'approved'),
    'card_count', (SELECT count(*) FROM public.card_topups c WHERE c.user_id = _user_id AND c.status = 'approved'),
    'card_total', (SELECT COALESCE(sum(c.net_amount),0) FROM public.card_topups c WHERE c.user_id = _user_id AND c.status = 'approved'),
    'order_count', (SELECT count(*) FROM public.orders o WHERE o.user_id = _user_id),
    'order_total', (SELECT COALESCE(sum(o.price),0) FROM public.orders o WHERE o.user_id = _user_id),
    'service_count', (SELECT count(*) FROM public.service_orders s WHERE s.user_id = _user_id),
    'service_total', (SELECT COALESCE(sum(s.price),0) FROM public.service_orders s WHERE s.user_id = _user_id),
    'is_admin', public.has_role(_user_id, 'admin')
  ) INTO res;
  RETURN res;
END;
$$;

ALTER TABLE public.site_settings
  ADD COLUMN IF NOT EXISTS spin_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS spin_cost bigint NOT NULL DEFAULT 5000;

CREATE TABLE IF NOT EXISTS public.spin_prizes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  label text NOT NULL,
  amount bigint NOT NULL DEFAULT 0,
  weight integer NOT NULL DEFAULT 1,
  sort integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.spin_prizes TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.spin_prizes TO authenticated;
GRANT ALL ON public.spin_prizes TO service_role;
ALTER TABLE public.spin_prizes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "read spin prizes" ON public.spin_prizes FOR SELECT USING (true);
CREATE POLICY "admin manage spin prizes" ON public.spin_prizes FOR ALL TO authenticated
  USING (has_role(auth.uid(), 'admin')) WITH CHECK (has_role(auth.uid(), 'admin'));

CREATE TABLE IF NOT EXISTS public.spin_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  prize_label text NOT NULL,
  amount bigint NOT NULL DEFAULT 0,
  cost bigint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.spin_history TO authenticated;
GRANT ALL ON public.spin_history TO service_role;
ALTER TABLE public.spin_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own spin history" ON public.spin_history FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR has_role(auth.uid(), 'admin'));

CREATE OR REPLACE FUNCTION public.spin_wheel()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uid uuid := auth.uid();
  cost bigint;
  enabled boolean;
  bal bigint;
  is_banned boolean;
  total_weight bigint;
  pick bigint;
  acc bigint := 0;
  chosen public.spin_prizes;
  r public.spin_prizes;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  SELECT spin_cost, spin_enabled INTO cost, enabled FROM public.site_settings WHERE id = 1;
  IF NOT COALESCE(enabled, false) THEN RAISE EXCEPTION 'minigame_disabled'; END IF;
  SELECT wallet_balance, banned INTO bal, is_banned FROM public.profiles WHERE id = uid;
  IF COALESCE(is_banned, false) THEN RAISE EXCEPTION 'user_banned'; END IF;
  IF bal IS NULL OR bal < COALESCE(cost,0) THEN RAISE EXCEPTION 'insufficient_balance'; END IF;

  SELECT COALESCE(sum(weight),0) INTO total_weight FROM public.spin_prizes WHERE weight > 0;
  IF total_weight <= 0 THEN RAISE EXCEPTION 'no_prizes'; END IF;

  pick := floor(random() * total_weight)::bigint;
  FOR r IN SELECT * FROM public.spin_prizes WHERE weight > 0 ORDER BY sort, created_at LOOP
    acc := acc + r.weight;
    IF pick < acc THEN chosen := r; EXIT; END IF;
  END LOOP;

  UPDATE public.profiles
     SET wallet_balance = wallet_balance - COALESCE(cost,0) + chosen.amount
   WHERE id = uid;

  INSERT INTO public.spin_history (user_id, prize_label, amount, cost)
  VALUES (uid, chosen.label, chosen.amount, COALESCE(cost,0));

  RETURN jsonb_build_object('prize_id', chosen.id, 'label', chosen.label, 'amount', chosen.amount, 'cost', COALESCE(cost,0));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_set_ban(uuid, boolean, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_user_summary(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.spin_wheel() FROM anon;

CREATE TABLE public.slip_refs (
  id uuid primary key default gen_random_uuid(),
  ref text not null unique,
  user_id uuid references auth.users(id) on delete set null,
  amount bigint,
  created_at timestamptz not null default now()
);
GRANT SELECT ON public.slip_refs TO authenticated;
GRANT ALL ON public.slip_refs TO service_role;
ALTER TABLE public.slip_refs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admin read slip refs" ON public.slip_refs FOR SELECT TO authenticated USING (public.has_role(auth.uid(),'admin'));

CREATE OR REPLACE FUNCTION public.claim_slip_ref(_ref text, _amount bigint DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
  _norm text := upper(regexp_replace(coalesce(_ref,''), '[^A-Za-z0-9]', '', 'g'));
BEGIN
  IF _uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF length(_norm) < 6 THEN RETURN true; END IF;
  IF EXISTS (SELECT 1 FROM public.slip_refs WHERE ref = _norm) THEN RETURN false; END IF;
  INSERT INTO public.slip_refs(ref, user_id, amount) VALUES (_norm, _uid, _amount);
  RETURN true;
END $$;

REVOKE ALL ON FUNCTION public.claim_slip_ref(text, bigint) FROM anon;
GRANT EXECUTE ON FUNCTION public.claim_slip_ref(text, bigint) TO authenticated;

CREATE TABLE public.payment_config (
  id integer PRIMARY KEY DEFAULT 1,
  api_url text,
  api_key text,
  merchant_name text NOT NULL DEFAULT 'SOMYONE KHAMKHEUNG MR.',
  timeout_minutes integer NOT NULL DEFAULT 15,
  webhook_secret text,
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.payment_config TO authenticated;
GRANT ALL ON public.payment_config TO service_role;
ALTER TABLE public.payment_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admin payment config" ON public.payment_config FOR ALL TO authenticated
  USING (has_role(auth.uid(),'admin')) WITH CHECK (has_role(auth.uid(),'admin'));
INSERT INTO public.payment_config (id) VALUES (1);

CREATE TABLE public.payment_intents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  amount bigint NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  qr_payload text,
  provider_txn_id text,
  bank_ref text,
  bank_payload jsonb,
  fail_reason text,
  expires_at timestamptz NOT NULL,
  settled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX payment_intents_bank_ref_uniq ON public.payment_intents (bank_ref) WHERE bank_ref IS NOT NULL;
CREATE INDEX payment_intents_user_idx ON public.payment_intents (user_id, created_at DESC);
GRANT SELECT ON public.payment_intents TO authenticated;
GRANT ALL ON public.payment_intents TO service_role;
ALTER TABLE public.payment_intents ENABLE ROW LEVEL SECURITY;
CREATE POLICY "own payment intents" ON public.payment_intents FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR has_role(auth.uid(),'admin'));

CREATE OR REPLACE FUNCTION public.expire_payment_intents()
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE public.payment_intents SET status='expired'
   WHERE status='pending' AND expires_at < now();
$$;

CREATE OR REPLACE FUNCTION public.create_payment_intent(_amount bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  uid uuid := auth.uid();
  cfg public.payment_config%ROWTYPE;
  is_banned boolean;
  existing public.payment_intents%ROWTYPE;
  row public.payment_intents%ROWTYPE;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF _amount IS NULL OR _amount < 1000 THEN RAISE EXCEPTION 'invalid_amount'; END IF;
  SELECT banned INTO is_banned FROM public.profiles WHERE id = uid;
  IF COALESCE(is_banned,false) THEN RAISE EXCEPTION 'user_banned'; END IF;
  SELECT * INTO cfg FROM public.payment_config WHERE id = 1;
  PERFORM public.expire_payment_intents();
  SELECT * INTO existing FROM public.payment_intents
    WHERE user_id = uid AND status='pending' ORDER BY created_at DESC LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('id', existing.id, 'amount', existing.amount,
      'expires_at', existing.expires_at, 'created_at', existing.created_at, 'reused', true);
  END IF;
  INSERT INTO public.payment_intents(user_id, amount, expires_at)
    VALUES (uid, _amount, now() + make_interval(mins => COALESCE(cfg.timeout_minutes,15)))
    RETURNING * INTO row;
  RETURN jsonb_build_object('id', row.id, 'amount', row.amount,
    'expires_at', row.expires_at, 'created_at', row.created_at, 'reused', false);
END $$;

CREATE OR REPLACE FUNCTION public.cancel_payment_intent(_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  UPDATE public.payment_intents SET status='cancelled'
   WHERE id = _id AND status='pending'
     AND (user_id = auth.uid() OR public.has_role(auth.uid(),'admin'));
END $$;

CREATE OR REPLACE FUNCTION public.settle_payment_intent(_id uuid, _ok boolean, _bank_ref text, _payload jsonb, _reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE row public.payment_intents%ROWTYPE;
BEGIN
  SELECT * INTO row FROM public.payment_intents WHERE id = _id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'intent_not_found'; END IF;
  IF row.status <> 'pending' THEN RETURN jsonb_build_object('ok', false, 'already', row.status); END IF;
  IF NOT _ok THEN
    UPDATE public.payment_intents
       SET status='failed', bank_ref=_bank_ref, bank_payload=_payload,
           fail_reason=_reason, settled_at=now()
     WHERE id=_id;
    RETURN jsonb_build_object('ok', false);
  END IF;
  UPDATE public.payment_intents
     SET status='success', bank_ref=_bank_ref, bank_payload=_payload, settled_at=now()
   WHERE id=_id;
  UPDATE public.profiles SET wallet_balance = wallet_balance + row.amount WHERE id = row.user_id;
  INSERT INTO public.topups(user_id, amount, status, method, note)
    VALUES (row.user_id, row.amount, 'approved', 'laoqr', COALESCE(_bank_ref,''));
  RETURN jsonb_build_object('ok', true, 'user_id', row.user_id, 'amount', row.amount);
END $$;

REVOKE ALL ON FUNCTION public.settle_payment_intent(uuid, boolean, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.settle_payment_intent(uuid, boolean, text, jsonb, text) TO service_role;

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $fn$
BEGIN NEW.updated_at = now(); RETURN NEW; END $fn$;

CREATE TRIGGER payment_config_updated_at BEFORE UPDATE ON public.payment_config
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

REVOKE ALL ON FUNCTION public.expire_payment_intents() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_payment_intents() TO service_role;
REVOKE ALL ON FUNCTION public.create_payment_intent(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_payment_intent(bigint) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.cancel_payment_intent(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_payment_intent(uuid) TO authenticated, service_role;
