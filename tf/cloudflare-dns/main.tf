module "cloudflare_dns" {
  source = "../modules/cloudflare"

  zones                 = var.zones
  secret_zones_main     = var.secret_zones_main
  secret_zones_stage    = var.secret_zones_stage
  secret_zones_archive  = var.secret_zones_archive
  secret_zones_inactive = var.secret_zones_inactive
}
