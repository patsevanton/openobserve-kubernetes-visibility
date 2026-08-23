# Создание сервисного аккаунта для управления Kubernetes
resource "yandex_iam_service_account" "sa_k8s_editor" {
  folder_id = local.folder_id
  name      = "openobserve-sa-k8s-editor" # Имя сервисного аккаунта
}

# Назначение роли "editor" сервисному аккаунту на уровне папки
resource "yandex_resourcemanager_folder_iam_member" "sa_k8s_editor_permissions" {
  folder_id = local.folder_id
  role      = "editor"                                                        # Роль, дающая полные права на ресурсы папки
  member    = "serviceAccount:${yandex_iam_service_account.sa_k8s_editor.id}" # Назначаемый участник
}

# Пауза, чтобы изменения IAM успели примениться до создания кластера
resource "time_sleep" "wait_sa" {
  create_duration = "20s"
  depends_on = [
    yandex_iam_service_account.sa_k8s_editor,
    yandex_resourcemanager_folder_iam_member.sa_k8s_editor_permissions
  ]
}

# Создание Kubernetes-кластера в Yandex Cloud
resource "yandex_kubernetes_cluster" "openobserve" {
  name       = "openobserve" # Имя кластера
  folder_id  = local.folder_id
  network_id = local.network_id # Сеть, к которой подключается кластер

  master {
    version = "1.33" # Версия Kubernetes мастера
    regional {
      region = "ru-central1" # Регион размещения мастера (3 зоны отказоустойчивости)

      location {
        zone      = local.subnet_b_zone # Зона размещения мастера
        subnet_id = local.subnet_b_id   # Подсеть для мастера
      }

      location {
        zone      = local.subnet_d_zone # Зона размещения мастера
        subnet_id = local.subnet_d_id   # Подсеть для мастера
      }

      location {
        zone      = local.subnet_e_zone # Зона размещения мастера
        subnet_id = local.subnet_e_id   # Подсеть для мастера
      }
    }

    public_ip = true # Включение публичного IP для доступа к мастеру
  }

  # Сервисный аккаунт для управления кластером и нодами
  service_account_id      = yandex_iam_service_account.sa_k8s_editor.id
  node_service_account_id = yandex_iam_service_account.sa_k8s_editor.id

  release_channel = "STABLE" # Канал обновлений

  # Зависимость от ожидания применения IAM-ролей.
  # При destroy кластер должен удалиться ДО time_sleep.wait_lb_release (пауза перед освобождением IP),
  # чтобы cloud-controller-manager успел снять LoadBalancer с адреса yandex_vpc_address.addr.
  depends_on = [
    time_sleep.wait_sa,
    time_sleep.wait_lb_release,
  ]
}

# Группа узлов для Kubernetes-кластера (HA-стек OpenObserve: 5 ролей + Postgres x2 + NATS x3,
# плюс agent-коллектор как DaemonSet на каждой ноде — поэтому 3 ноды, по одной на зону)
resource "yandex_kubernetes_node_group" "k8s_node_group" {
  description = "Node group for the Managed Service for Kubernetes cluster"
  name        = "openobserve-node-group"
  cluster_id  = yandex_kubernetes_cluster.openobserve.id
  version     = "1.33" # Версия Kubernetes на нодах

  scale_policy {
    fixed_scale {
      size = 3 # Кол-во нод
    }
  }

  allocation_policy {
    # Распределение нод по зонам отказоустойчивости
    location { zone = local.subnet_b_zone }
    location { zone = local.subnet_d_zone }
    location { zone = local.subnet_e_zone }
  }

  instance_template {
    platform_id = "standard-v3"

    network_interface {
      nat = false # Публичные IP на нодах выключены; исходящий трафик через NAT-шлюз (см. net.tf)
      subnet_ids = [
        local.subnet_b_id,
        local.subnet_d_id,
        local.subnet_e_id
      ]
    }

    resources {
      cores  = 2 # vCPU
      memory = 4 # ГБ
    }

    boot_disk {
      type = "network-ssd" # Тип диска
      size = 30            # Размер диска
    }
  }
}

# Настройка провайдера Helm для установки чарта в Kubernetes
provider "helm" {
  kubernetes = {
    host                   = yandex_kubernetes_cluster.openobserve.master[0].external_v4_endpoint   # Адрес API Kubernetes
    cluster_ca_certificate = yandex_kubernetes_cluster.openobserve.master[0].cluster_ca_certificate # CA-сертификат
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["k8s", "create-token"] # Команда получения токена через CLI Yandex.Cloud
      command     = "yc"
    }
  }
}

# Установка ingress-nginx через Helm
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  chart            = "oci://cr.yandex/yc-marketplace/yandex-cloud/ingress-nginx/chart/ingress-nginx"
  version          = "4.13.0"
  namespace        = "ingress-nginx"
  create_namespace = true

  depends_on = [
    yandex_kubernetes_cluster.openobserve,
    yandex_kubernetes_node_group.k8s_node_group,
    time_sleep.wait_lb_release,
  ]

  values = [
    yamlencode({
      controller = {
        replicaCount = 2
        podDisruptionBudget = {
          enabled      = true
          minAvailable = 1
        }
        service = {
          loadBalancerIP = local.ingress_public_ip
        }
      }
    })
  ]
}

# Вывод команды для получения kubeconfig
output "k8s_cluster_credentials_command" {
  value = "yc managed-kubernetes cluster get-credentials --id ${yandex_kubernetes_cluster.openobserve.id} --external --force"
}

output "ingress_public_ip" {
  description = "External ingress-nginx IP"
  value       = local.ingress_public_ip
}

output "openobserve_fqdn" {
  description = "FQDN OpenObserve (сформирован через sslip.io из публичного IP балансировщика ingress-nginx)"
  value       = local.openobserve_fqdn
}

output "openobserve_url" {
  description = "URL OpenObserve за ingress-nginx (http, TLS не настроен)"
  value       = "http://${local.openobserve_fqdn}"
}
