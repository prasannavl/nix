workers = {
  gap3-ai = {
    compatibility_date = "2026-03-23"
    assets = {
      directory = "../pkgs/cloudflare-apps/gap3-ai"
      config = {
        run_worker_first = false
      }
    }
    custom_domains = [
      {
        zone_name     = "gap3.ai"
        custom_domain = "gap3.ai"
      }
    ]
  }
}
