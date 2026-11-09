-- =====================================================================
-- 0012_local_auth.sql
-- Credentials and server-side sessions for the LOCAL / self-hosted auth
-- adapter.
--
-- Production on Supabase uses Supabase Auth and does not need these
-- tables; the auth layer picks an adapter at runtime (AUTH_PROVIDER).
-- They exist so the ERP runs on any PostgreSQL with no external
-- dependency -- which is what makes local development and CI possible.
--
-- Server-side sessions (rather than stateless JWTs) are deliberate:
-- deactivating a user or revoking a session takes effect on the very
-- next request, which is what the security model promises.
-- =====================================================================

CREATE TABLE user_credentials (
  user_id              uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  -- scrypt: salt + derived key, both hex, joined by ':'. No native
  -- dependency, and scrypt is memory-hard by design.
  password_hash        text NOT NULL,
  must_change_password boolean NOT NULL DEFAULT false,
  failed_attempts      integer NOT NULL DEFAULT 0,
  locked_until         timestamptz,
  password_changed_at  timestamptz NOT NULL DEFAULT now(),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_credentials_attempts_chk CHECK (failed_attempts >= 0)
);

CREATE TABLE user_sessions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- Only the hash is stored: a database leak does not yield live tokens.
  token_hash   text NOT NULL UNIQUE,
  ip_address   inet,
  user_agent   text,
  expires_at   timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  revoked_at   timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX user_sessions_user_idx ON user_sessions(user_id);
CREATE INDEX user_sessions_expiry_idx ON user_sessions(expires_at) WHERE revoked_at IS NULL;

CREATE TRIGGER user_credentials_updated_at BEFORE UPDATE ON user_credentials
  FOR EACH ROW EXECUTE FUNCTION app.set_updated_at();

-- Neither table is ever reachable from a browser role.
ALTER TABLE user_credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_credentials FORCE ROW LEVEL SECURITY;
ALTER TABLE user_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_sessions FORCE ROW LEVEL SECURITY;
REVOKE ALL ON user_credentials FROM authenticated, anon;
REVOKE ALL ON user_sessions FROM authenticated, anon;
CREATE POLICY user_credentials_service ON user_credentials
  FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY user_sessions_service ON user_sessions
  FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE TRIGGER user_credentials_audit AFTER INSERT OR UPDATE OR DELETE ON user_credentials
  FOR EACH ROW EXECUTE FUNCTION app.audit_trigger('SECURITY');
