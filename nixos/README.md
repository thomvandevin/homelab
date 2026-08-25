# NixOS Notes

## Building NixOS flake

As the NixOS flake is in the dir `./nixos` we need to use the `?dir` parameter for the flake and then the flake path. For example:

**Example dir parameter**

```sh
$ sudo nixos-rebuild switch --flake "github:thomvandevin/homelab?dir=nixos#<flake>"
```

**Working `nixos-rebuild switch` full path**

```sh
$ sudo nixos-rebuild switch --flake "github:thomvandevin/homelab?dir=nixos#homelab-0"
```

## Cross-compile with AARCH

Start colima container with rosetta virtualisation

```sh
$ colima start --profile vm --vm-type=vz --vz-rosetta --memory 8
```

Run `nix` commands with `./inside-docker <command>` using the specified docker host (vm)

```sh
$ DOCKER_HOST=unix:///Users/thomvandevin/.colima/vm/docker.sock ./inside-docker <command>
```

## Deploy with NixOS Anywhere

Boot the target from a NixOS installer ISO, add your SSH key to the `nixos`
user, then check `lsblk` against the `device` in `disko-configuration.nix`
before running anything: disko formats that disk unconditionally.

Seed the host key first (see Secrets), then:

```sh
nix run github:nix-community/nixos-anywhere \
--extra-experimental-features "nix-command flakes" \
-- --flake '.#homelab-0' \
   --build-on remote \
   --extra-files ./extra-files \
   --target-host nixos@host
```

`--build-on remote` avoids needing an x86_64-linux builder on macOS, so the
`./inside-docker` colima route is only needed if the target is too small to
build for itself.

## Secrets

`sops.age.sshKeyPaths` derives the decryption key from the host's
`/etc/ssh/ssh_host_ed25519_key`, which is regenerated on every reinstall. Keep
the personal key (`../key.txt`) as the first recipient in `.sops.yaml` so a dead
or reinstalled machine never takes the secrets with it.

To reinstall a host, generate its key up front rather than fixing sops
afterwards, so decryption works on first boot instead of failing activation:

```sh
mkdir -p extra-files/etc/ssh
ssh-keygen -t ed25519 -N "" -C "root@homelab-0" -f extra-files/etc/ssh/ssh_host_ed25519_key
chmod 600 extra-files/etc/ssh/ssh_host_ed25519_key

nix run nixpkgs#ssh-to-age -- -i extra-files/etc/ssh/ssh_host_ed25519_key.pub
```

Replace that host's entry in `.sops.yaml` with the printed `age1...` key, then
re-encrypt and pass `extra-files` to nixos-anywhere:

```sh
sops --encrypt --input-type yaml --output-type yaml secrets.yaml.dec > secrets.yaml
```

Verify you can still decrypt without the server before deploying:

```sh
SOPS_AGE_KEY_FILE=../key.txt sops --decrypt secrets.yaml
```
