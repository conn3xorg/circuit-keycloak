# circuit-keycloak

A Conn3x circuit that runs [Keycloak](https://www.keycloak.org), the open source identity and access management server, on your own hosts. Single sign-on, OpenID Connect and SAML for your apps, with the users and sessions on a machine you run.

It downloads a pinned Keycloak release from GitHub, checks its SHA-256, unpacks it into `/opt/keycloak/VERSION` with `/opt/keycloak/current` pointing at it, and runs it under systemd as a `keycloak` user on OpenJDK from your distribution. You set the hostname, how it listens and which database it uses; the circuit writes `/etc/keycloak/keycloak.conf` from them, runs `kc.sh build` when an option Keycloak bakes into the install changes, and restarts it with `start --optimized`. On the first start, Keycloak creates a temporary admin in the master realm from `admin_username` and `admin_password`.

Out of the box Keycloak listens on `127.0.0.1:8080` for a reverse proxy in front, trusts that proxy's `X-Forwarded-*` headers, and keeps its data in the dev-file database in `/var/lib/keycloak`.

> **The dev-file database is for labs and trials.** It's an embedded H2 file that Keycloak supports for development only: one node, and a backup means stopping Keycloak and copying the file. For anything you'd miss, use PostgreSQL. See [PostgreSQL](#postgresql) below.

## Usage

```hcl
variable "keycloak_admin_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "keycloak" {
  source = "github.com/conn3xorg/circuit-keycloak?ref=v0.1.0"

  hosts                = { auth1 = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  hostname       = "https://auth.example.com"
  admin_password = var.keycloak_admin_password
}
```

Then run `conn3x init` and `conn3x apply`, with the password in `TF_VAR_keycloak_admin_password`. Keycloak can take a minute to start, and the apply waits for it. A second `conn3x plan` says `No changes.`

Keycloak speaks plain HTTP here, for a TLS proxy on the same host such as [circuit-caddy](https://github.com/conn3xorg/circuit-caddy) with a reverse proxy to `127.0.0.1:8080`. Set `hostname` to the URL people type, so links and token issuers use it. To serve HTTPS from Keycloak itself, set `tls_certificate_file` and `tls_key_file` to a certificate and key already on the host, such as ones [circuit-certbot](https://github.com/conn3xorg/circuit-certbot) keeps, and `proxy_headers = null` when nothing sits in front. Plain HTTP is then off, and Keycloak listens on `https_port`, 8443 by default.

### The admin user

Keycloak 26 reads `KC_BOOTSTRAP_ADMIN_USERNAME` and `KC_BOOTSTRAP_ADMIN_PASSWORD` only when it starts against an empty database, and creates a temporary admin from them. The circuit writes both to `/etc/keycloak/bootstrap-admin.env`, root only, which the unit loads.

Once Keycloak has a database, changing `admin_password` rewrites that file and changes nothing else; the apply doesn't fail and doesn't restart Keycloak. Change the admin's password in the admin console, or with `kcadm.sh set-password`, and it stays changed. The bootstrap admin is meant to be temporary: create a permanent admin in the master realm, then delete it.

### PostgreSQL

The database and role must exist; [circuit-postgres](https://github.com/conn3xorg/circuit-postgres) can make both on the same host:

```hcl
module "postgres" {
  source = "github.com/conn3xorg/circuit-postgres?ref=v0.2.0"

  hosts          = { auth1 = "203.0.113.10" }
  users          = ["keycloak"]
  user_passwords = { keycloak = var.keycloak_db_password }
  databases      = { keycloak = "keycloak" }
}

module "keycloak" {
  source     = "github.com/conn3xorg/circuit-keycloak?ref=v0.1.0"
  depends_on = [module.postgres]

  hosts             = { auth1 = { address = "203.0.113.10", os = "ubuntu" } }
  hostname          = "https://auth.example.com"
  admin_password    = var.keycloak_admin_password
  postgres          = {}
  postgres_password = var.keycloak_db_password
}
```

`postgres = {}` means `127.0.0.1:5432`, database `keycloak`, user `keycloak`. Set `host`, `port`, `database` or `username` for anything else. `os` is there because `depends_on` holds back reading the host until the apply.

Switching from dev-file to PostgreSQL starts Keycloak on an empty database, with a new bootstrap admin. Nothing is copied across; export realms first with `kc.sh export` if you need them.

### Memory

Keycloak is a Java service, and with no `heap_size` it takes 70% of the host's memory for its heap. On a 2 GB host it sat at about 500 MB resident with nothing to do. A 1 GB host runs it with `heap_size = "512m"`, but with about 30 MB of memory left available and no swap, so it's fine for a lab and not for real traffic. 2 GB or more is the comfortable start.

To try it on a throwaway container first, see [examples/local](examples/local).

## What it does

On each host, in order:

1. Installs `curl`, `tar`, `gzip` and the OpenJDK runtime, `openjdk-25-jre-headless` on Debian and Ubuntu or `java-25-openjdk-headless` on Fedora and Rocky Linux, if they're missing.
2. Creates the `keycloak` system user and `/var/lib/keycloak` for its data, and `/etc/keycloak`, which `keycloak` can read but not write.
3. Downloads `keycloak-VERSION.tar.gz` from the GitHub release to `/opt/keycloak`. If the checksum doesn't match `keycloak_sha256`, the apply fails and nothing is unpacked.
4. Unpacks it into `/opt/keycloak/VERSION`, owned by root, and links `/opt/keycloak/VERSION/data` to `/var/lib/keycloak`, so the database, transaction logs and anything else Keycloak writes lives outside the versioned directory.
5. Writes `/etc/keycloak/keycloak.conf`, owned by root with mode `0640`.
6. Runs `kc.sh build` as root on a new release, or when the database vendor or `metrics_enabled` changes. Those are the build-time options the circuit sets; everything else is read at start.
7. Points `/opt/keycloak/current` at the release and writes `/etc/keycloak/bootstrap-admin.env` and `/etc/systemd/system/keycloak.service`.
8. Restarts Keycloak when the build, the release, `keycloak.conf` or the unit changed, starts it now and at boot, and waits up to five minutes for `/health/ready` on the management port to answer.

`keycloak.conf` is write-only: it reaches the host, but the plan and state hold only an HMAC of it, since it can carry the PostgreSQL password. A change to any input shows in the plan as `content_hmac` changing. The bootstrap admin file is write-only too. See [Secrets](https://docs.conn3x.org/reference/circuits/secrets) for the HMAC key Conn3x uses.

The unit runs Keycloak with `ProtectSystem=strict`, so it can write only to `/var/lib/keycloak`. The bootstrap admin variables stay in the service's environment, which only root can read.

Before the circuit runs, the `conn3x_host` data source reads each host's distribution and architecture over SSH. The distribution picks the Java package; the architecture is part of Java's directory name on Debian and Ubuntu.

### What it doesn't do

- It doesn't open a firewall port or get a certificate. Use [circuit-firewall](https://github.com/conn3xorg/circuit-firewall) for ports and a proxy or circuit-certbot for TLS.
- It doesn't create realms, clients or users beyond the bootstrap admin. Use the admin console, `kcadm.sh`, or the [Keycloak provider](https://registry.terraform.io/providers/keycloak/keycloak/latest) against the running server.
- It doesn't cluster. Each host is a single Keycloak with its own cache.
- It doesn't take backups. With PostgreSQL, back up the database; with dev-file, stop Keycloak and copy `/var/lib/keycloak`.
- It doesn't check the release's GPG signature on the host. The default checksum was taken from the 26.8.1 tarball, which matched the release's `.sha1` file and carried a good signature from the Keycloak Bot key, `861AB50E8CC6611FB6BC01A6B8F12EA26FD6EEBA`.
- It doesn't remove old releases after an upgrade, or their tarballs.
- Deleting the module leaves Keycloak installed and running, with its data.

### Upgrading

Keycloak publishes a `.sha1` and a `.asc` signature beside each tarball, but no SHA-256, so take one yourself after checking the others:

```sh
v=26.8.1
for s in "" .sha1 .asc; do
  curl -sSfLO https://github.com/keycloak/keycloak/releases/download/$v/keycloak-$v.tar.gz$s
done
gpg --verify keycloak-$v.tar.gz.asc keycloak-$v.tar.gz
echo "$(cat keycloak-$v.tar.gz.sha1)  keycloak-$v.tar.gz" | sha1sum -c -
sha256sum keycloak-$v.tar.gz
```

```hcl
module "keycloak" {
  source = "github.com/conn3xorg/circuit-keycloak?ref=v0.1.0"

  # ...
  keycloak_version = "26.8.1"
  keycloak_sha256  = "4e2740b181faa2ea623a1c2ecf00855935311e546046e2f857615a47ed24cbe8"
}
```

The new release unpacks beside the old one, gets built, and `/opt/keycloak/current` moves to it before Keycloak restarts and migrates its database. The old directory stays, so going back is a matter of setting the old version again, as long as the migration allows it. Back up the database first and read Keycloak's [upgrading guide](https://www.keycloak.org/docs/latest/upgrading/). Once you're happy, remove the old `/opt/keycloak/VERSION` directory and tarball by hand.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan or behind `depends_on` needs. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `keycloak_version` | string | `"26.8.1"` | Keycloak release to install. Raising it upgrades Keycloak in place. |
| `keycloak_sha256` | string | The 26.8.1 checksum | SHA-256 of `keycloak-VERSION.tar.gz`. Change it with `keycloak_version`. |
| `java_version` | number | `25` | OpenJDK release from the distribution's packages, `21` or `25`. Fedora 45 packages only 25. |
| `admin_username` | string | `"admin"` | Name of the temporary admin Keycloak creates on its first start. |
| `admin_password` | string | Required | Password of the temporary admin, at least 8 characters, with no quotes, backslashes, dollar signs or whitespace. Used on the first start only. Ephemeral and sensitive, so it's kept out of state. |
| `hostname` | string | `null` | URL people reach Keycloak by, such as `"https://auth.example.com"`. When null, `hostname-strict=false`, and Keycloak takes it from each request, which is fine for a lab and wrong for anything public. |
| `proxy_headers` | string | `"xforwarded"` | Proxy headers Keycloak trusts: `"xforwarded"`, `"forwarded"`, or `null` when nothing sits in front of it. |
| `http_host` | string | `"127.0.0.1"` | Address Keycloak and its management port listen on. `"0.0.0.0"` listens on every address. |
| `http_port` | number | `8080` | Port of plain HTTP, used without `tls_certificate_file`. |
| `https_port` | number | `8443` | Port of HTTPS, used with `tls_certificate_file`. |
| `management_port` | number | `9000` | Port of the management interface, which serves `/health` and `/metrics`. It uses HTTPS when Keycloak does. |
| `tls_certificate_file` | string | `null` | Path on the host of a PEM certificate chain. Set it with `tls_key_file` to serve HTTPS and turn plain HTTP off. `keycloak` must be able to read it. |
| `tls_key_file` | string | `null` | Path on the host of the certificate's PEM private key. `keycloak` must be able to read it. |
| `postgres` | object | `null` | PostgreSQL connection: `host` (`"127.0.0.1"`), `port` (`5432`), `database` (`"keycloak"`) and `username` (`"keycloak"`). When null, the dev-file database in `/var/lib/keycloak`. |
| `postgres_password` | string | `null` | Password of the PostgreSQL user, needed with `postgres`. Ephemeral and sensitive, so it's kept out of state. Can't hold a backslash or a dollar sign. |
| `metrics_enabled` | bool | `false` | Serve Prometheus metrics at `/metrics` on the management port. Changing it rebuilds Keycloak. |
| `heap_size` | string | `null` | JVM heap, as both `-Xms` and `-Xmx`, such as `"512m"` or `"1g"`. When null, 70% of the host's memory. |

## Outputs

| Name | Description |
| --- | --- |
| `config_file` | Path of the configuration file, `/etc/keycloak/keycloak.conf`. |
| `url` | URL the circuit reaches Keycloak on from each host itself, such as `http://127.0.0.1:8080`. |
| `health_url` | Readiness URL on the management port, such as `http://127.0.0.1:9000/health/ready`. |

## Requirements

Requires Conn3x v0.6.7 or later, systemd on each host, and outbound HTTPS to github.com and your distribution's mirrors. Each release takes about 370 MB of disk, tarball included. amd64 and arm64.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13, with Keycloak 26.8.1 on OpenJDK 25. CI applies [examples/local](examples/local) to each on amd64 and checks that the second plan has no changes. It then checks that `/health/ready` is `UP`, gets a token for the bootstrap admin from the master realm, checks that a wrong password is refused, creates a realm over the admin REST API and reads it back, restarts Keycloak, reads the realm again and plans again with no changes. The same checks passed on arm64 containers of all four by hand.

By hand, in containers: on Debian 13, an upgrade from 26.8.0 to 26.8.1 with `metrics_enabled` turned on in the same apply, which rebuilt Keycloak, kept the realm and served `/metrics`, and `heap_size = "512m"`, which reached the JVM; on Debian 13 with circuit-postgres on the same host and `postgres = {}`, a password holding `;` and `#`, which Keycloak used, with the password in neither the state nor the plan output; on Fedora 45, HTTPS from a certificate on the host with `hostname` set, where the issuer matched `hostname`, plain HTTP was off and the admin API answered over HTTPS; and on Rocky Linux 10, a changed `admin_password`, which applied cleanly without a restart.

On an Ubuntu 24.04 droplet with 1 vCPU and 1 GB of memory and `heap_size = "512m"`, and a Rocky Linux 10 droplet with SELinux enforcing, 2 vCPUs and 2 GB, the same checks passed. Keycloak was ready 53 seconds after its first start on the small droplet and 28 seconds on the larger one. On Rocky Linux it ran as `unconfined_service_t`, and the audit log had no denials. After a reboot both came back with the realm, and the plan had no changes.

## License

MPL-2.0. See [LICENSE](LICENSE). Keycloak itself is Apache-2.0.
