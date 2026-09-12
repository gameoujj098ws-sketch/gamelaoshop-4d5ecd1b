
REVOKE ALL ON FUNCTION public.admin_set_ban(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_ban(uuid, boolean, text) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_user_summary(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_user_summary(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.spin_wheel() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.spin_wheel() TO authenticated;
REVOKE ALL ON FUNCTION public.claim_slip_ref(text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_slip_ref(text, bigint) TO authenticated;
