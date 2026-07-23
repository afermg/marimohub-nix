# Import this flake's NixOS module and adapt the domains and users. This example
# keeps notebooks on local disk, authenticates static users through Dex, and runs
# kernels in rootless Podman containers built reproducibly as a Nix OCI image.
{ config, ... }:

{
  services.marimohub = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 3000;

    # Enables a lingering rootless Podman service for the marimohub account,
    # loads the flake's Nix-built sandbox image, and supplies the Docker-compatible
    # command expected by upstream's `docker` compute adapter.
    podman.enable = true;

    dex = {
      enable = true;
      issuer = "https://auth.example.com/dex";
      redirectUri = "https://hub.example.com/api/auth/callback";
      allowInsecureHttp = false;
      environmentFile = "/run/keys/marimohub.env";
      allowedEmailDomains = [ "example.com" ];
      users = [
        {
          email = "alice@example.com";
          username = "alice";
          userId = "alice";
          passwordHashEnv = "DEX_ALICE_PASSWORD_HASH";
        }
      ];
    };

    settings = {
      MARIMOHUB_STORAGE_BACKEND = "fs";
      MARIMOHUB_STORAGE_FS_ROOT = "/var/lib/marimohub/storage";

      # The hub proxies private loopback kernel ports. Use this only for trusted
      # users: notebook code is served on the control plane's origin.
      MARIMOHUB_SANDBOX_EXPOSURE = "proxy";
      MARIMOHUB_SANDBOX_PROXY_ACK_UNTRUSTED = true;
      MARIMOHUB_APP_BASE_URL = "https://hub.example.com";

      MARIMOHUB_RUN_MAINTENANCE = true;
    };
  };

  virtualisation.podman.autoPrune.enable = true;

  services.caddy = {
    enable = true;
    virtualHosts = {
      "hub.example.com".extraConfig = ''
        reverse_proxy 127.0.0.1:${toString config.services.marimohub.port}
      '';
      "auth.example.com".extraConfig = ''
        reverse_proxy 127.0.0.1:${toString config.services.marimohub.dex.port}
      '';
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
