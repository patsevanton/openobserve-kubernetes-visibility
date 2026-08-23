# Кластер Managed Service for PostgreSQL: метаданные-стор OpenObserve
# (замена in-cluster CloudNativePG — master и реплики обслуживает Yandex Cloud)
resource "yandex_mdb_postgresql_cluster" "openobserve" {
  name        = "openobserve"
  folder_id   = local.folder_id
  network_id  = local.network_id
  environment = "PRESTABLE"
  description = "Metadata store for OpenObserve"

  security_group_ids = [yandex_vpc_security_group.pg.id]

  config {
    version = "17"

    resources {
      resource_preset_id = "s2.micro" # 2 vCPU / 8 GiB — достаточно для метаданных OpenObserve
      disk_type_id       = "network-ssd"
      disk_size          = 10 # GiB на хост
    }

    # Special FQDN вида c-<cluster_id>.rw.mdb.yandexcloud.net (master) и c-<cluster_id>.ro.mdb.yandexcloud.net
    # (самая свежая replica) — Terraform подставляет их в DSN OpenObserve (см. openobserve.tf / values.yaml.tftpl)
  }

  # HA-топология: primary + 2 реплики, по хосту в каждой зоне отказоустойчивости.
  # Автоматический failover обслуживает Managed Service.
  host {
    zone      = local.subnet_b_zone
    subnet_id = local.subnet_b_id
  }

  host {
    zone      = local.subnet_d_zone
    subnet_id = local.subnet_d_id
  }

  host {
    zone      = local.subnet_e_zone
    subnet_id = local.subnet_e_id
  }

  maintenance_window {
    type = "ANYTIME"
  }
}

# Пользователь БД OpenObserve
resource "yandex_mdb_postgresql_user" "openobserve" {
  cluster_id = yandex_mdb_postgresql_cluster.openobserve.id
  name       = "openobserve"
  password   = var.openobserve_postgres_password
  # OpenObserve держит пул соединений к master и к replica
  conn_limit = 200
}

# База метаданных OpenObserve
resource "yandex_mdb_postgresql_database" "openobserve" {
  cluster_id = yandex_mdb_postgresql_cluster.openobserve.id
  name       = "app"
  owner      = yandex_mdb_postgresql_user.openobserve.name
}

# Security group кластера БД: 6432 открыт только из приватных подсетей,
# где живут ноды Managed K8s (поды OpenObserve подключаются к БД напрямую)
resource "yandex_vpc_security_group" "pg" {
  name        = "openobserve-pg-sg"
  description = "Allow PostgreSQL 6432 from Managed K8s subnets only"
  network_id  = local.network_id

  ingress {
    protocol       = "TCP"
    description    = "PostgreSQL from Managed K8s subnets"
    port           = 6432
    v4_cidr_blocks = [yandex_vpc_subnet.openobserve-b.v4_cidr_blocks[0], yandex_vpc_subnet.openobserve-d.v4_cidr_blocks[0], yandex_vpc_subnet.openobserve-e.v4_cidr_blocks[0]]
  }

  egress {
    protocol       = "ANY"
    description    = "Any outgoing"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

variable "openobserve_postgres_password" {
  type        = string
  sensitive   = true
  description = "Пароль пользователя openobserve в кластере Managed PostgreSQL"
}

locals {
  # Special FQDN Managed PostgreSQL: .rw — текущий master (read-write),
  # .ro — самая свежая replica (read-only); порт 6432.
  # Поды OpenObserve живут в той же cloud-сети, поэтому sslmode=disable допустим.
  postgres_dsn    = "postgres://${yandex_mdb_postgresql_user.openobserve.name}:${var.openobserve_postgres_password}@c-${yandex_mdb_postgresql_cluster.openobserve.id}.rw.mdb.yandexcloud.net:6432/${yandex_mdb_postgresql_database.openobserve.name}?sslmode=disable"
  postgres_ro_dsn = "postgres://${yandex_mdb_postgresql_user.openobserve.name}:${var.openobserve_postgres_password}@c-${yandex_mdb_postgresql_cluster.openobserve.id}.ro.mdb.yandexcloud.net:6432/${yandex_mdb_postgresql_database.openobserve.name}?sslmode=disable"
}

output "postgres_cluster_id" {
  description = "ID кластера Managed PostgreSQL (FQDN подключения: c-<id>.rw.mdb.yandexcloud.net)"
  value       = yandex_mdb_postgresql_cluster.openobserve.id
}
