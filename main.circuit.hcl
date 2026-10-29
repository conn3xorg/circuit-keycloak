# Facts give each host's distribution, which picks the Java package, and its
# architecture, which Debian and Ubuntu put in the Java directory's name.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os     = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  family = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) ? "debian" : "redhat" }

  java_package = {
    debian = "openjdk-${var.java_version}-jre-headless"
    redhat = "java-${var.java_version}-openjdk-headless"
  }
  debian_arch = { x86_64 = "amd64", aarch64 = "arm64" }
  java_home = { for name, f in local.family : name => f == "debian" ?
    "/usr/lib/jvm/java-${var.java_version}-openjdk-${lookup(local.debian_arch, data.conn3x_host.facts[name].arch, data.conn3x_host.facts[name].arch)}" :
    "/usr/lib/jvm/jre-${var.java_version}"
  }

  v       = var.keycloak_version
  base    = "/opt/keycloak"
  home    = "${local.base}/${local.v}"
  tarball = "${local.base}/keycloak-${local.v}.tar.gz"
  data    = "/var/lib/keycloak"
  etc     = "/etc/keycloak"
  config  = "${local.etc}/keycloak.conf"
  env     = "${local.etc}/bootstrap-admin.env"

  tls    = var.tls_certificate_file != null
  scheme = local.tls ? "https" : "http"

  # Where the circuit itself talks to Keycloak. 0.0.0.0 and :: listen on
  # loopback too.
  local_host = lookup({ "0.0.0.0" = "127.0.0.1", "::" = "[::1]" }, var.http_host, strcontains(var.http_host, ":") ? "[${var.http_host}]" : var.http_host)
  url        = "${local.scheme}://${local.local_host}:${local.tls ? var.https_port : var.http_port}"
  ready_url  = "${local.scheme}://${local.local_host}:${var.management_port}/health/ready"

  database = var.postgres == null ? ["db=dev-file"] : [
    "db=postgres",
    "db-url-host=${var.postgres.host}",
    "db-url-port=${var.postgres.port}",
    "db-url-database=${var.postgres.database}",
    "db-username=${var.postgres.username}",
    "db-password=${coalesce(var.postgres_password, "-")}",
  ]

  listener = local.tls ? [
    "http-enabled=false",
    "https-port=${var.https_port}",
    "https-certificate-file=${var.tls_certificate_file}",
    "https-certificate-key-file=${var.tls_key_file}",
    ] : [
    "http-enabled=true",
    "http-port=${var.http_port}",
  ]

  keycloak_conf = join("\n", concat(
    ["# Written by Conn3x. Changes here are overwritten on the next apply.", ""],
    ["# Build-time options. Changing one reruns kc.sh build."],
    slice(local.database, 0, 1),
    ["health-enabled=true", "metrics-enabled=${var.metrics_enabled}", ""],
    var.hostname == null ? ["hostname-strict=false"] : ["hostname=${var.hostname}"],
    var.proxy_headers == null ? [] : ["proxy-headers=${var.proxy_headers}"],
    ["http-host=${var.http_host}"],
    local.listener,
    ["http-management-port=${var.management_port}", ""],
    slice(local.database, 1, length(local.database)),
    [""],
  ))
}

circuit "keycloak" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # curl and tar fetch and unpack the release; curl also waits for Keycloak
  # to come up.
  step "tools" {
    for_each = toset(["curl", "tar", "gzip"])
    package {
      name = item.value
    }
  }

  step "java" {
    package {
      name = local.java_package[local.family[each.key]]
    }
  }

  step "user" {
    user {
      name   = "keycloak"
      system = true
      home   = local.data
      shell  = "/usr/sbin/nologin"
    }
  }

  # Keycloak's data directory, which holds the dev-file database. It lives
  # outside the versioned install, so an upgrade keeps it.
  step "data_dir" {
    directory {
      path  = local.data
      owner = "keycloak"
      group = "keycloak"
      mode  = "0750"
    }
  }

  # keycloak.conf and the bootstrap admin file belong to root, and keycloak
  # can only read the first, so Keycloak can't rewrite its own settings.
  step "config_dir" {
    directory {
      path  = local.etc
      owner = "root"
      group = "keycloak"
      mode  = "0750"
    }
  }

  step "tarball" {
    download {
      url    = "https://github.com/keycloak/keycloak/releases/download/${local.v}/keycloak-${local.v}.tar.gz"
      sha256 = var.keycloak_sha256
      dest   = local.tarball
    }
  }

  # Unpacked by hand rather than with an archive step, so the files belong
  # to root instead of the uid that built the release.
  step "unpack" {
    command {
      command = "cd ${local.base} && rm -rf .unpack && mkdir .unpack && tar --no-same-owner -xzf ${local.tarball} -C .unpack && rm -rf ${local.v} && mv .unpack/keycloak-${local.v} ${local.v} && rmdir .unpack"
      creates = "${local.home}/bin/kc.sh"
    }
  }

  step "data_link" {
    link {
      path   = "${local.home}/data"
      target = local.data
    }
  }

  # Write-only, since it can hold the PostgreSQL password: the plan and
  # state record only an HMAC of the content.
  step "config" {
    file {
      path       = local.config
      content_wo = local.keycloak_conf
      owner      = "root"
      group      = "keycloak"
      mode       = "0640"
    }
  }

  # Keycloak bakes the database vendor and its health and metrics endpoints
  # into the install, so only those, or a new release, call for a build.
  # It runs as root, and writes into the versioned directory.
  step "build" {
    command {
      command = "JAVA_HOME=${local.java_home[each.key]} ${local.home}/bin/kc.sh --config-file=${local.config} build"
      triggers = {
        unpack  = conn3x_command.keycloak__unpack[each.key].revision
        db      = var.postgres == null ? "dev-file" : "postgres"
        metrics = var.metrics_enabled
      }
    }
  }

  step "current" {
    link {
      path   = "${local.base}/current"
      target = local.v
    }
  }

  # Keycloak reads these only on the first start against an empty database,
  # to create the temporary admin. systemd reads the file as root, so it can
  # stay root-only.
  step "bootstrap_admin" {
    file {
      path       = local.env
      content_wo = "KC_BOOTSTRAP_ADMIN_USERNAME=\"${var.admin_username}\"\nKC_BOOTSTRAP_ADMIN_PASSWORD=\"${var.admin_password}\"\n"
      owner      = "root"
      group      = "root"
      mode       = "0600"
    }
  }

  step "unit" {
    file {
      path    = "/etc/systemd/system/keycloak.service"
      content = <<-EOT
        [Unit]
        Description=Keycloak
        After=network-online.target
        Wants=network-online.target

        [Service]
        User=keycloak
        Group=keycloak
        WorkingDirectory=${local.data}
        EnvironmentFile=${local.env}
        Environment=JAVA_HOME=${local.java_home[each.key]}${var.heap_size == null ? "" : " \"JAVA_OPTS_KC_HEAP=-Xms${var.heap_size} -Xmx${var.heap_size}\""}
        ExecStart=${local.base}/current/bin/kc.sh --config-file=${local.config} start --optimized
        # The JVM exits with 143 when systemd stops it with SIGTERM.
        SuccessExitStatus=143
        Restart=on-failure
        TimeoutStartSec=300
        LimitNOFILE=65536
        AmbientCapabilities=CAP_NET_BIND_SERVICE
        CapabilityBoundingSet=CAP_NET_BIND_SERVICE
        NoNewPrivileges=true
        ProtectSystem=strict
        PrivateTmp=true
        ReadWritePaths=${local.data}

        [Install]
        WantedBy=multi-user.target
      EOT
    }
  }

  # A step rather than a handler, so the check below waits for the Keycloak
  # that runs the new release and settings. Handlers run at the end of the
  # circuit, and a plan straight after the apply would find it still
  # starting. On a first apply it's what starts Keycloak.
  step "restart" {
    command {
      command = "systemctl daemon-reload && systemctl restart keycloak"
      triggers = {
        build   = conn3x_command.keycloak__build[each.key].revision
        current = conn3x_link.keycloak__current[each.key].revision
        config  = conn3x_file.keycloak__config[each.key].revision
        unit    = conn3x_file.keycloak__unit[each.key].revision
      }
    }
  }

  step "running" {
    service {
      name    = "keycloak"
      state   = "started"
      enabled = true
    }
  }

  # Keycloak takes up to a minute or so to start, more on a first start while
  # it creates its database. unless is checked at plan time, before the
  # restart, so the restart's revision makes the apply check again.
  step "ready" {
    command {
      command  = "for _ in $(seq 300); do curl -sfk -o /dev/null ${local.ready_url} && exit 0; sleep 1; done; echo 'Keycloak did not report ready in 5 minutes. See journalctl -u keycloak.' >&2; exit 1"
      unless   = "curl -sfk -o /dev/null ${local.ready_url}"
      triggers = { restart = conn3x_command.keycloak__restart[each.key].revision }
    }
  }
}
