# marimohub-nix

A reproducible Nix package and hardened NixOS service for
[marimohub](https://github.com/marimo-team/marimohub), a self-hosted platform for
storing, managing, and running marimo notebooks.

## What this flake exports

- `packages.<system>.marimohub`: self-contained Node server and web UI
- `nixosModules.marimohub`: `services.marimohub` NixOS module
- `overlays.default`: `pkgs.marimohub`
- a NixOS VM integration test for the service, health endpoint, and UI

The package is pinned to upstream commit
[`2a51039`](https://github.com/marimo-team/marimohub/commit/2a510392920d8263a34eae91a0ed76393512629b).
It is newer than the `v0.1.2` tag because upstream's filesystem storage backend,
needed for an all-local single-host deployment, landed after that release.

## Add it to a NixOS flake

```nix
{
  inputs.marimohub-nix.url = "github:afermg/marimohub-nix";

  outputs = { nixpkgs, marimohub-nix, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      modules = [
        marimohub-nix.nixosModules.marimohub
        ./configuration.nix
      ];
    };
  };
}
```

## Minimal smoke-test configuration

This is intentionally non-durable and unauthenticated. Do not expose it:

```nix
services.marimohub = {
  enable = true;
  settings = {
    MARIMOHUB_STORAGE_BACKEND = "memory";
    MARIMOHUB_ALLOW_EPHEMERAL_STORAGE = true;
    MARIMOHUB_COMPUTE_BACKEND = "none";
    MARIMOHUB_AUTH_BACKEND = "dev";
  };
};
```

After rebuilding, open <http://127.0.0.1:3000> or check:

```console
$ curl http://127.0.0.1:3000/api/health
{"status":"ok"}
```

## Single-host production shape

[`examples/single-host.nix`](./examples/single-host.nix) is an end-to-end NixOS
example with:

- durable filesystem storage under `/var/lib/marimohub/storage`;
- one Docker container per notebook kernel;
- private loopback kernel ports proxied through marimohub;
- OIDC authentication;
- Caddy TLS termination; and
- only ports 80/443 open.

Copy the example and replace the domain, OIDC provider, email domain, and sandbox
image. Put secrets in a root-owned file outside the Nix store. The example expects
`/run/keys/marimohub.env`, normally materialized at boot by sops-nix, agenix, or
another secret manager. Generate the session secret with:

```console
$ openssl rand -base64 32
```

Set `MARIMOHUB_AUTH_OIDC_CLIENT_SECRET` and
`MARIMOHUB_AUTH_SESSION_SECRET`. The OIDC callback URL is
`https://<host>/api/auth/callback`.

> **Security:** proxy exposure serves notebook code on the application's origin.
> A malicious notebook can act as the signed-in user. The single-host example is
> suitable only for a trusted team. For mutually untrusted users, use upstream's
> isolated sandbox-domain design and a production compute backend.

> **Docker access:** membership in the `docker` group and access to
> `/var/run/docker.sock` are effectively root access. Do not share this host with
> unrelated workloads.

## Configuration

All upstream settings go in `services.marimohub.settings` using their exact
environment-variable names. Booleans and integers are converted to strings.
Consult the pinned upstream
[configuration reference](https://github.com/marimo-team/marimohub/blob/2a510392920d8263a34eae91a0ed76393512629b/docs/configuration.md).

Module-specific options:

| Option | Default | Purpose |
| --- | --- | --- |
| `enable` | `false` | Enable the service |
| `package` | pinned package | Package to run |
| `listenAddress` | `127.0.0.1` | Bind address (downstream patch) |
| `port` | `3000` | HTTP port |
| `openFirewall` | `false` | Open the HTTP port |
| `settings` | `{}` | Non-secret upstream environment |
| `environmentFiles` | `[]` | systemd env files for secrets |
| `runtimePackages` | `[]` | Tools such as `pkgs.docker` |
| `supplementaryGroups` | `[]` | Groups such as `docker` |
| `user`, `group` | `marimohub` | Service identity |

Values in `settings` enter the world-readable Nix store. Use
`environmentFiles` for credentials, signing keys, and API tokens.

The module deliberately does not invent backend defaults. Upstream fails closed
unless storage, compute, and auth are selected. This makes accidental ephemeral
storage or development authentication less likely.

## Other deployment models

The module passes arbitrary upstream configuration through unchanged. S3/GCS
storage and Modal, CoreWeave, W&B, Docker, local, or no compute can be selected
through `settings`. For example, with S3 keep only the non-secret bucket/region
in `settings` and place access keys in `environmentFiles`—or omit static keys and
use the AWS SDK's ambient credential chain.

Upstream treats the E2B and Kubernetes JavaScript SDKs as bring-your-own runtime
dependencies. This lean package does not bundle those optional SDKs, so those two
compute backends require a package override that adds them.

The service runs one maintenance loop when
`MARIMOHUB_RUN_MAINTENANCE=true`. On this single-process NixOS module, enable it.
Filesystem storage supports exactly one hub process; use S3 or GCS before
scaling outside this module.

## Build and test

```console
$ nix build
$ nix flake check
$ nix fmt -- --ci
```

## Updating upstream

Update `version`, `rev`, source hash, and `pnpmDeps.hash` in
[`package.nix`](./package.nix), then run `nix build`. With an empty dependency
hash, Nix prints the correct fixed-output hash.

## License

The Nix integration is MIT licensed. marimohub itself is Apache-2.0 licensed.
