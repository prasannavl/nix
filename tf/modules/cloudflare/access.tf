locals {
  access_policies_resolved = {
    for key, policy in var.access_policies : key => merge(policy, {
      include = length(try(policy.include, [])) == 0 ? null : [
        for rule in try(policy.include, []) : merge(
          rule,
          try(rule.login_method.id, null) != null ? {
            login_method = merge(rule.login_method, {
              id = try(cloudflare_zero_trust_access_identity_provider.identity_provider[rule.login_method.id].id, rule.login_method.id)
            })
          } : {},
          try(rule.group.id, null) != null ? {
            group = merge(rule.group, {
              id = try(cloudflare_zero_trust_access_group.group[rule.group.id].id, rule.group.id)
            })
          } : {},
          try(rule.auth_context.identity_provider_id, null) != null ? {
            auth_context = merge(rule.auth_context, {
              identity_provider_id = try(
                cloudflare_zero_trust_access_identity_provider.identity_provider[rule.auth_context.identity_provider_id].id,
                rule.auth_context.identity_provider_id,
              )
            })
          } : {},
        )
      ]
      exclude = length(try(policy.exclude, [])) == 0 ? null : [
        for rule in try(policy.exclude, []) : merge(
          rule,
          try(rule.login_method.id, null) != null ? {
            login_method = merge(rule.login_method, {
              id = try(cloudflare_zero_trust_access_identity_provider.identity_provider[rule.login_method.id].id, rule.login_method.id)
            })
          } : {},
          try(rule.group.id, null) != null ? {
            group = merge(rule.group, {
              id = try(cloudflare_zero_trust_access_group.group[rule.group.id].id, rule.group.id)
            })
          } : {},
          try(rule.auth_context.identity_provider_id, null) != null ? {
            auth_context = merge(rule.auth_context, {
              identity_provider_id = try(
                cloudflare_zero_trust_access_identity_provider.identity_provider[rule.auth_context.identity_provider_id].id,
                rule.auth_context.identity_provider_id,
              )
            })
          } : {},
        )
      ]
      require = length(try(policy.require, [])) == 0 ? null : [
        for rule in try(policy.require, []) : merge(
          rule,
          try(rule.login_method.id, null) != null ? {
            login_method = merge(rule.login_method, {
              id = try(cloudflare_zero_trust_access_identity_provider.identity_provider[rule.login_method.id].id, rule.login_method.id)
            })
          } : {},
          try(rule.group.id, null) != null ? {
            group = merge(rule.group, {
              id = try(cloudflare_zero_trust_access_group.group[rule.group.id].id, rule.group.id)
            })
          } : {},
          try(rule.auth_context.identity_provider_id, null) != null ? {
            auth_context = merge(rule.auth_context, {
              identity_provider_id = try(
                cloudflare_zero_trust_access_identity_provider.identity_provider[rule.auth_context.identity_provider_id].id,
                rule.auth_context.identity_provider_id,
              )
            })
          } : {},
        )
      ]
    })
  }

  access_applications_resolved = {
    for key, application in var.access_applications : key => merge(application, {
      allowed_idps = length(try(application.allowed_idps, [])) == 0 ? null : [
        for idp_id in try(application.allowed_idps, []) : try(
          cloudflare_zero_trust_access_identity_provider.identity_provider[idp_id].id,
          idp_id,
        )
      ]
      policies = [
        for policy in try(application.policies, []) : merge(
          policy,
          try(policy.id, null) != null ? {
            id = try(cloudflare_zero_trust_access_policy.policy[policy.id].id, policy.id)
          } : {},
          length(try(policy.include, [])) > 0 ? {
            include = [
              for rule in try(policy.include, []) : merge(
                rule,
                try(rule.login_method.id, null) != null ? {
                  login_method = merge(rule.login_method, {
                    id = try(cloudflare_zero_trust_access_identity_provider.identity_provider[rule.login_method.id].id, rule.login_method.id)
                  })
                } : {},
                try(rule.group.id, null) != null ? {
                  group = merge(rule.group, {
                    id = try(cloudflare_zero_trust_access_group.group[rule.group.id].id, rule.group.id)
                  })
                } : {},
                try(rule.auth_context.identity_provider_id, null) != null ? {
                  auth_context = merge(rule.auth_context, {
                    identity_provider_id = try(
                      cloudflare_zero_trust_access_identity_provider.identity_provider[rule.auth_context.identity_provider_id].id,
                      rule.auth_context.identity_provider_id,
                    )
                  })
                } : {},
              )
            ]
          } : {},
          length(try(policy.exclude, [])) > 0 ? {
            exclude = [
              for rule in try(policy.exclude, []) : merge(
                rule,
                try(rule.login_method.id, null) != null ? {
                  login_method = merge(rule.login_method, {
                    id = try(cloudflare_zero_trust_access_identity_provider.identity_provider[rule.login_method.id].id, rule.login_method.id)
                  })
                } : {},
                try(rule.group.id, null) != null ? {
                  group = merge(rule.group, {
                    id = try(cloudflare_zero_trust_access_group.group[rule.group.id].id, rule.group.id)
                  })
                } : {},
                try(rule.auth_context.identity_provider_id, null) != null ? {
                  auth_context = merge(rule.auth_context, {
                    identity_provider_id = try(
                      cloudflare_zero_trust_access_identity_provider.identity_provider[rule.auth_context.identity_provider_id].id,
                      rule.auth_context.identity_provider_id,
                    )
                  })
                } : {},
              )
            ]
          } : {},
          length(try(policy.require, [])) > 0 ? {
            require = [
              for rule in try(policy.require, []) : merge(
                rule,
                try(rule.login_method.id, null) != null ? {
                  login_method = merge(rule.login_method, {
                    id = try(cloudflare_zero_trust_access_identity_provider.identity_provider[rule.login_method.id].id, rule.login_method.id)
                  })
                } : {},
                try(rule.group.id, null) != null ? {
                  group = merge(rule.group, {
                    id = try(cloudflare_zero_trust_access_group.group[rule.group.id].id, rule.group.id)
                  })
                } : {},
                try(rule.auth_context.identity_provider_id, null) != null ? {
                  auth_context = merge(rule.auth_context, {
                    identity_provider_id = try(
                      cloudflare_zero_trust_access_identity_provider.identity_provider[rule.auth_context.identity_provider_id].id,
                      rule.auth_context.identity_provider_id,
                    )
                  })
                } : {},
              )
            ]
          } : {},
        )
      ]
    })
  }
}

resource "cloudflare_zero_trust_access_identity_provider" "identity_provider" {
  for_each = var.access_identity_providers

  account_id  = var.cloudflare_account_id
  name        = try(each.value.name, null)
  type        = each.value.type
  config      = try(each.value.config, {})
  scim_config = each.value.type == "onetimepin" ? null : try(each.value.scim_config, null)
}

resource "cloudflare_zero_trust_access_group" "group" {
  for_each = var.access_groups

  account_id = var.cloudflare_account_id
  name       = try(each.value.name, each.key)
  include    = try(each.value.include, null)
  exclude    = try(each.value.exclude, null)
  require    = try(each.value.require, null)
  is_default = try(each.value.is_default, null)
}

resource "cloudflare_zero_trust_access_policy" "policy" {
  for_each = local.access_policies_resolved

  account_id                     = var.cloudflare_account_id
  name                           = try(each.value.name, each.key)
  decision                       = each.value.decision
  include                        = try(each.value.include, null)
  exclude                        = try(each.value.exclude, null)
  require                        = try(each.value.require, null)
  session_duration               = try(each.value.session_duration, null)
  approval_required              = try(each.value.approval_required, null)
  approval_groups                = try(each.value.approval_groups, null)
  connection_rules               = try(each.value.connection_rules, null)
  isolation_required             = try(each.value.isolation_required, null)
  mfa_config                     = try(each.value.mfa_config, null)
  purpose_justification_prompt   = try(each.value.purpose_justification_prompt, null)
  purpose_justification_required = try(each.value.purpose_justification_required, null)
}

resource "cloudflare_zero_trust_access_application" "application" {
  for_each = local.access_applications_resolved

  account_id                      = var.cloudflare_account_id
  name                            = try(each.value.name, each.key)
  type                            = try(each.value.type, null)
  domain                          = try(each.value.domain, null)
  self_hosted_domains             = try(each.value.destinations, null) != null ? null : try(each.value.self_hosted_domains, null)
  destinations                    = try(each.value.destinations, null)
  session_duration                = try(each.value.session_duration, null)
  allowed_idps                    = try(each.value.allowed_idps, null)
  app_launcher_visible            = try(each.value.app_launcher_visible, null)
  auto_redirect_to_identity       = try(each.value.auto_redirect_to_identity, null)
  enable_binding_cookie           = try(each.value.enable_binding_cookie, null)
  http_only_cookie_attribute      = try(each.value.http_only_cookie_attribute, null)
  options_preflight_bypass        = try(each.value.options_preflight_bypass, null)
  same_site_cookie_attribute      = try(each.value.same_site_cookie_attribute, null)
  skip_app_launcher_login_page    = try(each.value.skip_app_launcher_login_page, null)
  skip_interstitial               = try(each.value.skip_interstitial, null)
  allow_iframe                    = try(each.value.allow_iframe, null)
  allow_authenticate_via_warp     = try(each.value.allow_authenticate_via_warp, null)
  path_cookie_attribute           = try(each.value.path_cookie_attribute, null)
  service_auth_401_redirect       = try(each.value.service_auth_401_redirect, null)
  read_service_tokens_from_header = try(each.value.read_service_tokens_from_header, null)
  app_launcher_logo_url           = try(each.value.app_launcher_logo_url, null)
  bg_color                        = try(each.value.bg_color, null)
  custom_deny_message             = try(each.value.custom_deny_message, null)
  custom_deny_url                 = try(each.value.custom_deny_url, null)
  custom_non_identity_deny_url    = try(each.value.custom_non_identity_deny_url, null)
  footer_links                    = try(each.value.footer_links, null)
  header_bg_color                 = try(each.value.header_bg_color, null)
  landing_page_design             = try(each.value.landing_page_design, null)
  logo_url                        = try(each.value.logo_url, null)
  cors_headers                    = try(each.value.cors_headers, null)
  custom_pages                    = try(each.value.custom_pages, null)
  tags                            = try(each.value.tags, null)
  target_criteria                 = try(each.value.target_criteria, null)
  policies                        = try(each.value.policies, null)
}

output "managed_access_identity_providers" {
  value = {
    for key, provider in cloudflare_zero_trust_access_identity_provider.identity_provider : key => {
      id   = provider.id
      name = provider.name
      type = provider.type
    }
  }
}

output "managed_access_groups" {
  value = {
    for key, group in cloudflare_zero_trust_access_group.group : key => {
      id         = group.id
      name       = group.name
      is_default = try(group.is_default, false)
    }
  }
}

output "managed_access_policies" {
  value = {
    for key, policy in cloudflare_zero_trust_access_policy.policy : key => {
      id       = policy.id
      name     = policy.name
      decision = policy.decision
    }
  }
}

output "managed_access_applications" {
  value = {
    for key, application in cloudflare_zero_trust_access_application.application : key => {
      id     = application.id
      aud    = application.aud
      domain = try(application.domain, null)
      name   = application.name
      type   = application.type
    }
  }
}
