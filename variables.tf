variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel, centos or fedora."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "keycloak_version" {
  type        = string
  default     = "26.8.1"
  description = "Keycloak release to install, such as \"26.8.1\". Change keycloak_sha256 with it. Raising it installs the new release beside the old one and upgrades Keycloak in place."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.keycloak_version))
    error_message = "keycloak_version must be a release number such as \"26.8.1\"."
  }
}

variable "keycloak_sha256" {
  type        = string
  default     = "4e2740b181faa2ea623a1c2ecf00855935311e546046e2f857615a47ed24cbe8"
  description = "SHA-256 of keycloak-VERSION.tar.gz. Change it with keycloak_version."

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.keycloak_sha256))
    error_message = "keycloak_sha256 must be a SHA-256 in lowercase hex."
  }
}

variable "java_version" {
  type        = number
  default     = 25
  description = "OpenJDK release to run Keycloak on, from the distribution's packages: 21 or 25. Fedora 45 packages only 25."

  validation {
    condition     = contains([21, 25], var.java_version)
    error_message = "java_version must be 21 or 25, the releases Keycloak 26 supports."
  }
}

variable "admin_username" {
  type        = string
  default     = "admin"
  description = "Name of the temporary admin Keycloak creates in the master realm on its first start."

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.@-]*$", var.admin_username))
    error_message = "admin_username may use letters, digits, _, ., @ and -, and must start with a letter or digit."
  }
}

variable "admin_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Password of the temporary admin, set on Keycloak's first start only. Pass it at run time with -var or TF_VAR_admin_password; it never reaches state or the plan."

  # It goes into a systemd environment file in double quotes, so quotes,
  # backslashes and dollar signs are left out.
  validation {
    condition     = length(var.admin_password) >= 8 && !can(regex("[\"\\\\$'\\s]", var.admin_password))
    error_message = "admin_password must be at least 8 characters, with no quotes, backslashes, dollar signs or whitespace."
  }
}

variable "hostname" {
  type        = string
  default     = null
  description = "Address people reach Keycloak by, as a URL such as \"https://auth.example.com\" or a bare host name. Keycloak builds its links and token issuers from it. When null, Keycloak takes it from each request, with hostname-strict=false, which is fine for a lab and wrong for anything public."

  validation {
    condition     = var.hostname == null || can(regex("^(https?://)?[A-Za-z0-9.-]+(:[0-9]+)?(/[^\\s]*)?$", coalesce(var.hostname, "-")))
    error_message = "hostname must be a URL such as \"https://auth.example.com\" or a host name such as \"auth.example.com\"."
  }
}

variable "proxy_headers" {
  type        = string
  default     = "xforwarded"
  description = "Which headers from a reverse proxy Keycloak trusts for the client's address and scheme: \"xforwarded\", \"forwarded\", or null when nothing sits in front of it."

  validation {
    condition     = var.proxy_headers == null || contains(["xforwarded", "forwarded"], coalesce(var.proxy_headers, "-"))
    error_message = "proxy_headers must be \"xforwarded\", \"forwarded\" or null."
  }
}

variable "http_host" {
  type        = string
  default     = "127.0.0.1"
  description = "Address Keycloak listens on, for HTTP or HTTPS and its management port. The default keeps it to the host itself, for a proxy in front; \"0.0.0.0\" listens on every address."

  validation {
    condition     = can(cidrhost("${var.http_host}/${strcontains(var.http_host, ":") ? 128 : 32}", 0))
    error_message = "http_host must be an IP address, such as \"127.0.0.1\" or \"0.0.0.0\"."
  }
}

variable "http_port" {
  type        = number
  default     = 8080
  description = "Port of plain HTTP, used when tls_certificate_file is null."

  validation {
    condition     = var.http_port >= 1 && var.http_port <= 65535 && floor(var.http_port) == var.http_port
    error_message = "http_port must be a port number from 1 to 65535."
  }
}

variable "https_port" {
  type        = number
  default     = 8443
  description = "Port of HTTPS, used with tls_certificate_file."

  validation {
    condition     = var.https_port >= 1 && var.https_port <= 65535 && floor(var.https_port) == var.https_port
    error_message = "https_port must be a port number from 1 to 65535."
  }
}

variable "management_port" {
  type        = number
  default     = 9000
  description = "Port of Keycloak's management interface, which serves /health and /metrics."

  validation {
    condition     = var.management_port >= 1 && var.management_port <= 65535 && floor(var.management_port) == var.management_port
    error_message = "management_port must be a port number from 1 to 65535."
  }
}

variable "tls_certificate_file" {
  type        = string
  default     = null
  description = "Path on the host of a PEM certificate chain. When set, Keycloak serves HTTPS on https_port and turns plain HTTP off. The keycloak user must be able to read it."

  validation {
    condition     = var.tls_certificate_file == null || startswith(coalesce(var.tls_certificate_file, "-"), "/")
    error_message = "tls_certificate_file must be an absolute path."
  }

  validation {
    condition     = (var.tls_certificate_file == null) == (var.tls_key_file == null)
    error_message = "Set tls_certificate_file and tls_key_file together."
  }
}

variable "tls_key_file" {
  type        = string
  default     = null
  description = "Path on the host of the PEM private key of tls_certificate_file. The keycloak user must be able to read it."

  validation {
    condition     = var.tls_key_file == null || startswith(coalesce(var.tls_key_file, "-"), "/")
    error_message = "tls_key_file must be an absolute path."
  }
}

variable "postgres" {
  type = object({
    host     = optional(string, "127.0.0.1")
    port     = optional(number, 5432)
    database = optional(string, "keycloak")
    username = optional(string, "keycloak")
  })
  default     = null
  description = "PostgreSQL to keep Keycloak's data in, such as { host = \"db1\" }. The database and role must exist. When null, Keycloak uses its dev-file database in /var/lib/keycloak, which is for labs and trials only."

  validation {
    condition     = var.postgres == null || alltrue([for k, v in coalesce(var.postgres, {}) : can(regex("^[A-Za-z0-9_.:-]+$", tostring(v)))])
    error_message = "postgres host, database and username may use letters, digits and . _ - :."
  }
}

variable "postgres_password" {
  type        = string
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "Password of the postgres username. Needed with postgres. Pass it at run time with -var or TF_VAR_postgres_password; it never reaches state or the plan."

  validation {
    condition     = var.postgres == null || length(coalesce(var.postgres_password, "")) > 0
    error_message = "postgres needs postgres_password."
  }

  # keycloak.conf would read a backslash as an escape and ${ as a
  # placeholder.
  validation {
    condition     = !can(regex("[\\\\$\\n]", coalesce(var.postgres_password, "-")))
    error_message = "postgres_password can't hold a backslash, a dollar sign or a newline."
  }
}

variable "metrics_enabled" {
  type        = bool
  default     = false
  description = "Serve Prometheus metrics on the management port at /metrics. Changing it rebuilds Keycloak."
}

variable "heap_size" {
  type        = string
  default     = null
  description = "JVM heap, set as both -Xms and -Xmx, such as \"512m\" or \"1g\". When null, Keycloak sizes it at 70% of the host's memory."

  validation {
    condition     = var.heap_size == null || can(regex("^[1-9][0-9]*[mg]$", coalesce(var.heap_size, "-")))
    error_message = "heap_size must be a whole number of megabytes or gigabytes, such as \"512m\" or \"1g\"."
  }
}
