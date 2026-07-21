output "container_url" {
  description = "The container the CSV feeds land in (azure-service-tags/<tag>.csv and m365/<area>.csv)."
  value       = "https://${local.sa_name}.blob.core.windows.net/${local.container}"
}

output "run_now_command" {
  description = "Fire the weekly workflow immediately instead of waiting for Monday."
  value       = "az rest --method POST --url \"https://management.azure.com${module.logic_app_workflow.ids[local.wf_name]}/triggers/Recurrence_-_Every_Monday_at_06_00_UTC/run?api-version=2016-06-01\""
}

output "workflow_id" {
  description = "The workflow's resource id."
  value       = module.logic_app_workflow.ids[local.wf_name]
}

output "workflow_principal_id" {
  description = "The workflow's managed identity principal id."
  value       = module.logic_app_workflow.identities[local.wf_name].principal_id
}
