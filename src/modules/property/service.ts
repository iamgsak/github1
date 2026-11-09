import { queryOne, query, type RequestContext } from '@/lib/db';

export async function getProperty(propertyId: string, ctx?: RequestContext) {
  return queryOne<Record<string, string>>(
    `SELECT p.*, o.name AS organization_name
       FROM properties p JOIN organizations o ON o.id = p.organization_id
      WHERE p.id = $1`,
    [propertyId], ctx,
  );
}

export async function listUsers(organizationId: string, ctx?: RequestContext) {
  return query<Record<string, string>>(
    `SELECT u.id, u.full_name, u.email, u.is_active, u.last_login_at,
            ARRAY(SELECT r.name FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                   WHERE ur.user_id = u.id ORDER BY r.name) AS roles,
            (SELECT count(*)::int FROM user_roles ur
               JOIN role_permissions rp ON rp.role_id = ur.role_id
              WHERE ur.user_id = u.id) AS permission_count
       FROM users u WHERE u.organization_id = $1 ORDER BY u.full_name`,
    [organizationId], ctx,
  );
}

export async function listRolesWithCounts(ctx?: RequestContext) {
  return query<Record<string, string>>(
    `SELECT r.code, r.name, r.description, r.is_system,
            count(rp.permission_code)::int AS permission_count
       FROM roles r
       LEFT JOIN role_permissions rp ON rp.role_id = r.id
      WHERE r.is_system
      GROUP BY r.id, r.code, r.name, r.description, r.is_system
      ORDER BY count(rp.permission_code) DESC, r.name`,
    [], ctx,
  );
}
