data "cloudflare_zone" "zone" {
  for_each = local.zone_names

  filter = {
    match  = "all"
    name   = each.key
    status = "active"
  }
}

locals {
  secret_zone_groups = [
    var.secret_zones_main,
    var.secret_zones_stage,
    var.secret_zones_archive,
    var.secret_zones_inactive,
  ]

  worker_custom_domain_zone_names = toset(flatten([
    for worker_name, worker in var.workers : [
      for domain in try(worker.custom_domains, []) : domain.zone_name
    ]
  ]))

  worker_route_zone_names = toset(flatten([
    for worker_name, worker in var.workers : [
      for route in try(worker.routes, []) : route.zone_name
    ]
  ]))

  zone_names = toset(flatten(concat(
    [keys(var.zones)],
    [for group in local.secret_zone_groups : keys(group)],
    [tolist(local.worker_custom_domain_zone_names)],
    [tolist(local.worker_route_zone_names)]
  )))

  merged_zones = {
    for zone_name in local.zone_names : zone_name => {
      records = flatten(concat(
        try(var.zones[zone_name].records, []),
        [for group in local.secret_zone_groups : try(group[zone_name].records, [])]
      ))
    }
  }

  flattened_records = flatten([
    for zone_name, zone in local.merged_zones : [
      for record in zone.records : merge(record, {
        zone_name = zone_name
        tf_key    = "${zone_name}/${record.key}"
      })
    ]
  ])

  records = {
    for record in local.flattened_records : record.tf_key => record
  }
}

resource "cloudflare_dns_record" "record" {
  for_each = local.records

  zone_id  = data.cloudflare_zone.zone[each.value.zone_name].zone_id
  name     = each.value.name
  type     = upper(each.value.type)
  ttl      = try(each.value.ttl, 1)
  content  = try(each.value.content, null)
  proxied  = try(each.value.proxied, null)
  priority = try(each.value.priority, null)
  comment  = try(each.value.comment, null)
  tags     = try(each.value.tags, null)
  data     = try(each.value.data, null)
  settings = try(each.value.settings, null)

  lifecycle {
    create_before_destroy = true

    precondition {
      condition = (
        try(each.value.content, null) != null
        || try(each.value.data, null) != null
      )
      error_message = "Each DNS record must set `content` or `data`."
    }
  }
}

output "managed_records" {
  value = {
    for key, record in cloudflare_dns_record.record : key => {
      id      = record.id
      name    = record.name
      type    = record.type
      zone_id = record.zone_id
    }
  }
}
