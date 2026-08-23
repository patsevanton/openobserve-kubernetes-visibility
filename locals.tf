locals {
  folder_id  = var.folder_id
  network_id = yandex_vpc_network.openobserve.id

  subnet_b_id   = yandex_vpc_subnet.openobserve-b.id
  subnet_d_id   = yandex_vpc_subnet.openobserve-d.id
  subnet_e_id   = yandex_vpc_subnet.openobserve-e.id
  subnet_b_zone = yandex_vpc_subnet.openobserve-b.zone
  subnet_d_zone = yandex_vpc_subnet.openobserve-d.zone
  subnet_e_zone = yandex_vpc_subnet.openobserve-e.zone

  # Публичный IP балансировщика ingress-nginx. FQDN OpenObserve формируется через sslip.io
  # из этого адреса (см. outputs в k8s.tf и values.yaml).
  ingress_public_ip = yandex_vpc_address.addr.external_ipv4_address[0].address
  openobserve_fqdn  = "openobserve.${local.ingress_public_ip}.sslip.io"
}
