# Local example

Applies circuit-keycloak to a throwaway Rocky Linux 10 container with systemd. You need Conn3x and Podman, and about 1 GB of memory free for Keycloak.

```sh
./up.sh
export TF_VAR_admin_password=$(openssl rand -hex 12)
conn3x init
conn3x apply
conn3x plan
```

The apply waits for Keycloak to report ready, which can take a minute. The second plan says `No changes.` Keycloak listens on `127.0.0.1:8080` inside the container, with the dev-file database, and its health checks are on port 9000. To get a token for the admin:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 \
  curl -s 127.0.0.1:8080/realms/master/protocol/openid-connect/token \
  -d grant_type=password -d client_id=admin-cli -d username=admin -d password="$TF_VAR_admin_password"
```

To use the admin console from your browser, forward the port over SSH and open `http://localhost:8080`, then sign in as `admin`:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts -L 8080:127.0.0.1:8080 -N root@127.0.0.1
```

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
