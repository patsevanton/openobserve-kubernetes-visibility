locals {
  collector_values = templatefile("${path.module}/collector-values.yaml.tftpl", {
    openobserve_basic_auth_header = local.openobserve_basic_auth_header
  })
}

resource "local_file" "write_collector_values" {
  content         = local.collector_values
  filename        = "${path.module}/collector-values.yaml"
  file_permission = "0644"
}
