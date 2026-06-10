# cognito.tf — Cognito User Pool + hosted UI domain + per-app app clients.
# Single suite-wide user pool; one app client per app (wrapper|crm|fa).
# Pinned addresses (consumed by outputs.tf):
#   aws_cognito_user_pool.this
#   aws_cognito_user_pool_domain.this
#   aws_cognito_user_pool_client.clients[<app>]  (for_each = local.apps)

# ---------------------------------------------------------------------------
# User pool
# ---------------------------------------------------------------------------
resource "aws_cognito_user_pool" "this" {
  name = "${local.name_prefix}-users"

  # Sign in with email; auto-verify the email channel.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }

  # Self-service account recovery via verified email only.
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Allow self sign-up (admin-only creation disabled).
  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  # Custom attributes carrying suite identity claims into the JWT.
  # Mutable so the app backends can backfill/update them post-provisioning.
  schema {
    name                     = "internalUserId"
    attribute_data_type      = "String"
    mutable                  = true
    developer_only_attribute = false
    required                 = false
    string_attribute_constraints {
      min_length = 0
      max_length = 256
    }
  }

  schema {
    name                     = "tenantId"
    attribute_data_type      = "String"
    mutable                  = true
    developer_only_attribute = false
    required                 = false
    string_attribute_constraints {
      min_length = 0
      max_length = 256
    }
  }

  schema {
    name                     = "orgId"
    attribute_data_type      = "String"
    mutable                  = true
    developer_only_attribute = false
    required                 = false
    string_attribute_constraints {
      min_length = 0
      max_length = 256
    }
  }

  tags = {
    Name = "${local.name_prefix}-users"
  }
}

# ---------------------------------------------------------------------------
# Hosted UI domain (Cognito-managed prefix domain)
# ---------------------------------------------------------------------------
resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${var.cognito_domain_prefix}-${var.environment}"
  user_pool_id = aws_cognito_user_pool.this.id
}

# ---------------------------------------------------------------------------
# Per-app app clients (public clients — no secret; PKCE/SRP from SPAs+backends)
# ---------------------------------------------------------------------------
resource "aws_cognito_user_pool_client" "clients" {
  for_each = local.apps

  name         = "${each.key}-client"
  user_pool_id = aws_cognito_user_pool.this.id

  # Public client: no generated secret (SRP/PKCE auth from browser + backend).
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_PASSWORD_AUTH",
  ]

  # OAuth2 authorization-code flow via hosted UI.
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["email", "openid", "profile"]
  supported_identity_providers         = ["COGNITO"]

  # Backend-mediated OAuth: the app builds redirect_uri = ${BACKEND_URL}/api/auth/callback
  # and exchanges the code server-side, so the callback MUST be the API host (behind the
  # ALB), not the CloudFront SPA host. The frontend host is kept as an allowed return target.
  callback_urls = [
    "https://${local.fqdn[each.key].api}/api/auth/callback",
    "https://${local.fqdn[each.key].frontend}",
  ]
  logout_urls = [
    "https://${local.fqdn[each.key].frontend}",
  ]

  # Token lifetimes: short-lived access/id tokens, 30-day refresh.
  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  # Don't leak whether a username exists on failed auth.
  prevent_user_existence_errors = "ENABLED"
}

# ---------------------------------------------------------------------------
# Platform-admin group
# ---------------------------------------------------------------------------
# The PLATFORM plane (internal operators who manage platform staff and operate
# cross-tenant) is signalled by membership of this group, surfaced in tokens via
# the native `cognito:groups` claim. This is intentionally NOT a tenant DB role:
# `isSuperAdmin` is tenant-scoped and every tenant founder has it, so it must
# never confer cross-tenant access. The backend reads this group name from
# COGNITO_PLATFORM_ADMIN_GROUP (default "platform-admins").
#
# Seat the first admin via PLATFORM_ADMIN_BOOTSTRAP_EMAILS (break-glass) or by
# adding them to this group (AWS console / adminAddUserToGroup), then manage the
# rest through group membership.
resource "aws_cognito_user_group" "platform_admins" {
  name         = var.cognito_platform_admin_group
  user_pool_id = aws_cognito_user_pool.this.id
  description  = "Internal platform administrators (cross-tenant plane). Distinct from tenant admins."
  precedence   = 1
}
