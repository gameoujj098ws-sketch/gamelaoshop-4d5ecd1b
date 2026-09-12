
CREATE OR REPLACE VIEW public.public_stats
WITH (security_invoker = false) AS
SELECT
  (SELECT count(*) FROM public.profiles)::bigint AS members,
  (SELECT count(*) FROM public.page_views)::bigint AS visits,
  (SELECT count(*) FROM public.product_stock WHERE sold = false)::bigint AS available,
  (SELECT count(*) FROM public.product_stock WHERE sold = true)::bigint AS sold;

GRANT SELECT ON public.public_stats TO anon, authenticated;

CREATE TABLE IF NOT EXISTS public.card_topups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  card_code text NOT NULL,
  gross_amount bigint NOT NULL DEFAULT 10000,
  net_amount bigint NOT NULL DEFAULT 6000,
  status text NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT ON public.card_topups TO authenticated;
GRANT ALL ON public.card_topups TO service_role;

ALTER TABLE public.card_topups ENABLE ROW LEVEL SECURITY;

CREATE POLICY "own card topups"
  ON public.card_topups FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.has_role(auth.uid(), 'admin'));

CREATE POLICY "insert own card topup"
  ON public.card_topups FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "admin update card topup"
  ON public.card_topups FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(), 'admin'));

CREATE OR REPLACE FUNCTION public.submit_card_topup(_card text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
  _id uuid;
BEGIN
  IF _uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF _card IS NULL OR _card !~ '^\d{14}$' THEN RAISE EXCEPTION 'invalid_card'; END IF;
  INSERT INTO public.card_topups(user_id, card_code, gross_amount, net_amount, status)
    VALUES(_uid, _card, 10000, 6000, 'pending')
    RETURNING id INTO _id;
  RETURN jsonb_build_object('id', _id);
END $$;

REVOKE EXECUTE ON FUNCTION public.submit_card_topup(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_card_topup(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.approve_card_topup(_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _c public.card_topups%ROWTYPE;
BEGIN
  IF NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'not_admin'; END IF;
  SELECT * INTO _c FROM public.card_topups WHERE id = _id FOR UPDATE;
  IF NOT FOUND OR _c.status <> 'pending' THEN RAISE EXCEPTION 'invalid'; END IF;
  UPDATE public.card_topups SET status='approved' WHERE id=_id;
  UPDATE public.profiles SET wallet_balance = wallet_balance + _c.net_amount WHERE id = _c.user_id;
  INSERT INTO public.topups(user_id, amount, status, method) VALUES(_c.user_id, _c.net_amount, 'approved', 'card');
END $$;

CREATE OR REPLACE FUNCTION public.reject_card_topup(_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'not_admin'; END IF;
  UPDATE public.card_topups SET status='rejected' WHERE id=_id AND status='pending';
END $$;

REVOKE EXECUTE ON FUNCTION public.approve_card_topup(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.reject_card_topup(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.approve_card_topup(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reject_card_topup(uuid) TO authenticated;

CREATE TABLE public.service_packages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  name text NOT NULL,
  price bigint NOT NULL,
  image_url text,
  sort integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.service_packages TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.service_packages TO authenticated;
GRANT ALL ON public.service_packages TO service_role;
ALTER TABLE public.service_packages ENABLE ROW LEVEL SECURITY;
CREATE POLICY "read service packages" ON public.service_packages FOR SELECT USING (true);
CREATE POLICY "admin manage service packages" ON public.service_packages FOR ALL TO authenticated
  USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));

CREATE TABLE public.service_fields (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  label text NOT NULL,
  sort integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.service_fields TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.service_fields TO authenticated;
GRANT ALL ON public.service_fields TO service_role;
ALTER TABLE public.service_fields ENABLE ROW LEVEL SECURITY;
CREATE POLICY "read service fields" ON public.service_fields FOR SELECT USING (true);
CREATE POLICY "admin manage service fields" ON public.service_fields FOR ALL TO authenticated
  USING (public.has_role(auth.uid(),'admin')) WITH CHECK (public.has_role(auth.uid(),'admin'));

ALTER TABLE public.service_orders
  ADD COLUMN package_id uuid REFERENCES public.service_packages(id) ON DELETE SET NULL,
  ADD COLUMN package_name text,
  ADD COLUMN answers jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.site_settings
  ADD COLUMN qr_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN card_enabled boolean NOT NULL DEFAULT true;

CREATE OR REPLACE FUNCTION public.purchase_service_package(_product_id uuid, _package_id uuid, _answers jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid uuid := auth.uid();
  _prod public.products%ROWTYPE;
  _pack public.service_packages%ROWTYPE;
  _price bigint;
  _bal bigint;
  _oid uuid;
  _note text;
BEGIN
  IF _uid IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  SELECT * INTO _prod FROM public.products WHERE id = _product_id;
  IF NOT FOUND OR NOT _prod.is_service THEN RAISE EXCEPTION 'product_not_found'; END IF;
  IF _package_id IS NOT NULL THEN
    SELECT * INTO _pack FROM public.service_packages WHERE id = _package_id AND product_id = _product_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'package_not_found'; END IF;
    _price := _pack.price;
  ELSE
    _price := _prod.price;
  END IF;
  SELECT wallet_balance INTO _bal FROM public.profiles WHERE id = _uid FOR UPDATE;
  IF _bal < _price THEN RAISE EXCEPTION 'insufficient_balance'; END IF;
  SELECT string_agg(COALESCE(e->>'label','') || ': ' || COALESCE(e->>'value',''), E'\n')
    INTO _note FROM jsonb_array_elements(COALESCE(_answers,'[]'::jsonb)) e;
  UPDATE public.profiles SET wallet_balance = wallet_balance - _price WHERE id = _uid;
  INSERT INTO public.service_orders(user_id, product_id, product_name, price, customer_note, status, package_id, package_name, answers)
    VALUES(_uid, _product_id, _prod.name, _price, COALESCE(_note,''), 'pending', _package_id,
           CASE WHEN _package_id IS NULL THEN NULL ELSE _pack.name END, COALESCE(_answers,'[]'::jsonb))
    RETURNING id INTO _oid;
  RETURN jsonb_build_object('order_id', _oid);
END $$;
REVOKE EXECUTE ON FUNCTION public.purchase_service_package(uuid, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.purchase_service_package(uuid, uuid, jsonb) TO authenticated;

ALTER TABLE public.topups ADD COLUMN IF NOT EXISTS note text;
ALTER TABLE public.card_topups ADD COLUMN IF NOT EXISTS note text;
ALTER TABLE public.site_settings ADD COLUMN IF NOT EXISTS qr_account_name text NOT NULL DEFAULT 'SOMYONE KHAMKHEUNG';
