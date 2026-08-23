variable "openobserve_root_user_email" {
  type        = string
  description = "Email root-пользователя OpenObserve (ZO_ROOT_USER_EMAIL)"
}

variable "openobserve_root_user_password" {
  type        = string
  sensitive   = true
  description = "Пароль root-пользователя OpenObserve (ZO_ROOT_USER_PASSWORD)"
}

variable "openobserve_s3_bucket_name" {
  type        = string
  description = "Имя бакета Yandex Object Storage для данных OpenObserve"
}

locals {
  # Basic-заголовок для OTLP-экспортёров коллектора:
  # printf '%s:%s' "$EMAIL" "$PASS" | base64
  openobserve_basic_auth_header = base64encode("${var.openobserve_root_user_email}:${var.openobserve_root_user_password}")
}

# Сервисный аккаунт для доступа OpenObserve к бакету Object Storage
resource "yandex_iam_service_account" "sa_s3" {
  folder_id = local.folder_id
  name      = "openobserve-sa-s3"
}

# Роль на чтение/запись бакета: storage.editor (без storage.uploader — не умеет удалять,
# а компактору нужно применять retention и удалять файлы)
resource "yandex_resourcemanager_folder_iam_member" "sa_s3_permissions" {
  folder_id = local.folder_id
  role      = "storage.editor"
  member    = "serviceAccount:${yandex_iam_service_account.sa_s3.id}"
}

# Static access key для сервисного аккаунта — с ней OpenObserve ходит в S3 API
resource "yandex_iam_service_account_static_access_key" "sa_s3_key" {
  service_account_id = yandex_iam_service_account.sa_s3.id
  description        = "Static access key for OpenObserve S3 access"
}

# Бакет для данных OpenObserve (Parquet-файлы логов/метрик/трейсов)
resource "yandex_storage_bucket" "openobserve" {
  bucket     = var.openobserve_s3_bucket_name
  access_key = yandex_iam_service_account_static_access_key.sa_s3_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa_s3_key.secret_key
}

locals {
  openobserve_values = templatefile("${path.module}/values.yaml.tftpl", {
    openobserve_fqdn               = local.openobserve_fqdn
    openobserve_root_user_email    = var.openobserve_root_user_email
    openobserve_root_user_password = var.openobserve_root_user_password
    openobserve_s3_access_key      = yandex_iam_service_account_static_access_key.sa_s3_key.access_key
    openobserve_s3_secret_key      = yandex_iam_service_account_static_access_key.sa_s3_key.secret_key
    openobserve_s3_bucket_name     = var.openobserve_s3_bucket_name
  })
}

resource "local_file" "write_openobserve_values" {
  content         = local.openobserve_values
  filename        = "${path.module}/values.yaml"
  file_permission = "0644"
}
