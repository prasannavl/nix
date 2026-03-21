output "project_ids" {
  description = "Managed project IDs keyed by project name."
  value = {
    dev = module.dev.project_id
  }
}
