module "cloudflare_apps" {
  source = "../modules/cloudflare"

  zones                 = {}
  cloudflare_account_id = var.cloudflare_account_id
  workers               = merge(var.workers_main, var.workers_archive, var.workers_stage, var.workers)
  secrets               = var.secrets
}
