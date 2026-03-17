locals {
  r2_bucket_custom_domains_flat = flatten([
    for bucket_name, bucket in var.r2_buckets : [
      for index, domain in try(bucket.custom_domains, []) : merge(domain, {
        bucket_name = bucket_name
        tf_key      = "${bucket_name}/custom-domain/${index}"
      })
    ]
  ])

  r2_bucket_custom_domains = {
    for domain in local.r2_bucket_custom_domains_flat : domain.tf_key => domain
  }

  r2_bucket_event_notifications_flat = flatten([
    for bucket_name, bucket in var.r2_buckets : [
      for index, notification in try(bucket.event_notifications, []) : merge(notification, {
        bucket_name = bucket_name
        tf_key      = "${bucket_name}/event-notification/${index}"
      })
    ]
  ])

  r2_bucket_event_notifications = {
    for notification in local.r2_bucket_event_notifications_flat : notification.tf_key => notification
  }

  r2_custom_domain_zone_names = toset([
    for domain in local.r2_bucket_custom_domains_flat : domain.zone_name
  ])
}

data "cloudflare_zone" "r2_custom_domain_zone" {
  for_each = local.r2_custom_domain_zone_names

  filter = {
    match  = "all"
    name   = each.key
    status = "active"
  }
}

resource "cloudflare_r2_bucket" "bucket" {
  for_each = var.r2_buckets

  account_id    = var.cloudflare_account_id
  name          = each.key
  jurisdiction  = try(each.value.jurisdiction, null)
  location      = try(each.value.location, null)
  storage_class = try(each.value.storage_class, null)
}

resource "cloudflare_r2_bucket_cors" "cors" {
  for_each = {
    for bucket_name, bucket in var.r2_buckets : bucket_name => bucket
    if try(bucket.cors, null) != null
  }

  account_id   = var.cloudflare_account_id
  bucket_name  = each.key
  jurisdiction = try(each.value.jurisdiction, null)
  rules        = each.value.cors.rules

  depends_on = [cloudflare_r2_bucket.bucket]
}

resource "cloudflare_r2_bucket_lifecycle" "lifecycle" {
  for_each = {
    for bucket_name, bucket in var.r2_buckets : bucket_name => bucket
    if try(bucket.lifecycle, null) != null
  }

  account_id   = var.cloudflare_account_id
  bucket_name  = each.key
  jurisdiction = try(each.value.jurisdiction, null)
  rules        = try(each.value.lifecycle.rules, null)

  depends_on = [cloudflare_r2_bucket.bucket]
}

resource "cloudflare_r2_bucket_lock" "lock" {
  for_each = {
    for bucket_name, bucket in var.r2_buckets : bucket_name => bucket
    if try(bucket.lock, null) != null
  }

  account_id   = var.cloudflare_account_id
  bucket_name  = each.key
  jurisdiction = try(each.value.jurisdiction, null)
  rules        = try(each.value.lock.rules, null)

  depends_on = [cloudflare_r2_bucket.bucket]
}

resource "cloudflare_r2_managed_domain" "managed_domain" {
  for_each = {
    for bucket_name, bucket in var.r2_buckets : bucket_name => bucket
    if try(bucket.managed_domain, null) != null
  }

  account_id   = var.cloudflare_account_id
  bucket_name  = each.key
  jurisdiction = try(each.value.jurisdiction, null)
  enabled      = each.value.managed_domain.enabled

  depends_on = [cloudflare_r2_bucket.bucket]
}

resource "cloudflare_r2_custom_domain" "custom_domain" {
  for_each = local.r2_bucket_custom_domains

  account_id   = var.cloudflare_account_id
  bucket_name  = each.value.bucket_name
  jurisdiction = try(var.r2_buckets[each.value.bucket_name].jurisdiction, null)
  domain       = each.value.domain
  enabled      = each.value.enabled
  zone_id      = data.cloudflare_zone.r2_custom_domain_zone[each.value.zone_name].zone_id
  ciphers      = try(each.value.ciphers, null)
  min_tls      = try(each.value.min_tls, null)

  depends_on = [cloudflare_r2_bucket.bucket]
}

resource "cloudflare_r2_bucket_event_notification" "event_notification" {
  for_each = local.r2_bucket_event_notifications

  account_id   = var.cloudflare_account_id
  bucket_name  = each.value.bucket_name
  jurisdiction = try(var.r2_buckets[each.value.bucket_name].jurisdiction, null)
  queue_id     = each.value.queue_id
  rules        = each.value.rules

  depends_on = [cloudflare_r2_bucket.bucket]
}

resource "cloudflare_r2_bucket_sippy" "sippy" {
  for_each = {
    for bucket_name, bucket in var.r2_buckets : bucket_name => bucket
    if try(bucket.sippy, null) != null
  }

  account_id   = var.cloudflare_account_id
  bucket_name  = each.key
  jurisdiction = try(each.value.jurisdiction, null)
  source       = try(each.value.sippy.source, null)
  destination  = try(each.value.sippy.destination, null)

  depends_on = [cloudflare_r2_bucket.bucket]
}

output "managed_r2_buckets" {
  value = {
    for bucket_name, bucket in cloudflare_r2_bucket.bucket : bucket_name => {
      name           = bucket.name
      location       = bucket.location
      storage_class  = bucket.storage_class
      custom_domains = [for key, domain in cloudflare_r2_custom_domain.custom_domain : domain.domain if local.r2_bucket_custom_domains[key].bucket_name == bucket_name]
      managed_domain = try(cloudflare_r2_managed_domain.managed_domain[bucket_name].domain, null)
      event_queues   = [for key, notification in cloudflare_r2_bucket_event_notification.event_notification : notification.queue_id if local.r2_bucket_event_notifications[key].bucket_name == bucket_name]
      sippy_enabled  = contains(keys(cloudflare_r2_bucket_sippy.sippy), bucket_name)
    }
  }
}
