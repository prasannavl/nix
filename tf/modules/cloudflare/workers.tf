locals {
  worker_cron_triggers = {
    for worker_name, worker in var.workers : worker_name => worker.cron_triggers
    if length(try(worker.cron_triggers, [])) > 0
  }

  worker_routes_flat = flatten([
    for worker_name, worker in var.workers : [
      for index, route in try(worker.routes, []) : merge(route, {
        worker_name = worker_name
        tf_key      = "${worker_name}/route/${index}"
      })
    ]
  ])

  worker_routes = {
    for route in local.worker_routes_flat : route.tf_key => route
  }

  worker_custom_domains_flat = flatten([
    for worker_name, worker in var.workers : [
      for index, domain in try(worker.custom_domains, []) : merge(domain, {
        worker_name = worker_name
        tf_key      = "${worker_name}/domain/${index}"
      })
    ]
  ])

  worker_custom_domains = {
    for domain in local.worker_custom_domains_flat : domain.tf_key => domain
  }
}

resource "cloudflare_worker" "worker" {
  for_each = var.workers

  account_id = var.cloudflare_account_id
  name       = each.key
  logpush    = try(each.value.logpush, null)
  subdomain  = try(each.value.script_subdomain, null)

  observability = try(each.value.observability, null)

  lifecycle {
    precondition {
      condition = (
        var.cloudflare_account_id != null
        && trimspace(var.cloudflare_account_id) != ""
      )
      error_message = "Cloudflare Workers require `cloudflare_account_id` to be set, typically via an encrypted tfvars file under data/secrets/tf/cloudflare/."
    }
  }
}

resource "cloudflare_worker_version" "version" {
  for_each = var.workers

  account_id          = var.cloudflare_account_id
  worker_id           = cloudflare_worker.worker[each.key].name
  main_module         = each.value.main_module
  compatibility_date  = try(each.value.compatibility_date, null)
  compatibility_flags = try(each.value.compatibility_flags, null)
  annotations         = try(each.value.annotations, null)
  bindings            = try(each.value.bindings, null)
  limits              = try(each.value.limits, null)
  placement           = try(each.value.placement, null)

  assets = (
    try(each.value.assets, null) == null
    ? null
    : merge(each.value.assets, {
      directory = (
        try(each.value.assets.directory, null) == null
        ? null
        : abspath(
          startswith(each.value.assets.directory, "/")
          ? each.value.assets.directory
          : "${path.root}/${each.value.assets.directory}"
        )
      )
    })
  )

  modules = [
    for module in each.value.modules : merge(module, {
      content_file = abspath(
        startswith(module.content_file, "/")
        ? module.content_file
        : "${path.root}/${module.content_file}"
      )
    })
  ]
}

resource "cloudflare_workers_deployment" "deployment" {
  for_each = var.workers

  account_id  = var.cloudflare_account_id
  script_name = cloudflare_worker.worker[each.key].name
  strategy    = "percentage"
  versions = [{
    percentage = 100
    version_id = cloudflare_worker_version.version[each.key].id
  }]

  annotations = try(each.value.deployment_annotations, null)
}

resource "cloudflare_workers_cron_trigger" "cron_trigger" {
  for_each = local.worker_cron_triggers

  account_id  = var.cloudflare_account_id
  script_name = cloudflare_worker.worker[each.key].name
  schedules   = each.value

  depends_on = [cloudflare_workers_deployment.deployment]
}

resource "cloudflare_workers_route" "route" {
  for_each = local.worker_routes

  zone_id = data.cloudflare_zone.zone[each.value.zone_name].zone_id
  pattern = each.value.pattern
  script  = cloudflare_worker.worker[each.value.worker_name].name

  depends_on = [cloudflare_workers_deployment.deployment]
}

resource "cloudflare_workers_custom_domain" "domain" {
  for_each = local.worker_custom_domains

  account_id  = var.cloudflare_account_id
  hostname    = each.value.hostname
  service     = cloudflare_worker.worker[each.value.worker_name].name
  zone_id     = data.cloudflare_zone.zone[each.value.zone_name].zone_id
  environment = "production"

  depends_on = [cloudflare_workers_deployment.deployment]
}

output "managed_workers" {
  value = {
    for name, worker in cloudflare_worker.worker : name => {
      id            = worker.id
      version_id    = try(cloudflare_worker_version.version[name].id, null)
      deployment_id = try(cloudflare_workers_deployment.deployment[name].id, null)
      workers_dev   = try(worker.subdomain.enabled, null)
      cron_triggers = try([
        for schedule in cloudflare_workers_cron_trigger.cron_trigger[name].schedules : schedule.cron
      ], [])
      routes = [
        for route_key, route in cloudflare_workers_route.route : {
          id      = route.id
          pattern = route.pattern
          zone_id = route.zone_id
        }
        if local.worker_routes[route_key].worker_name == name
      ]
      custom_domains = [
        for domain_key, domain in cloudflare_workers_custom_domain.domain : {
          id       = domain.id
          hostname = domain.hostname
          zone_id  = domain.zone_id
        }
        if local.worker_custom_domains[domain_key].worker_name == name
      ]
    }
  }
}
