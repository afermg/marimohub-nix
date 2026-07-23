# Import this flake's NixOS module and adapt the domain, OIDC values, and image.
# This example keeps notebooks on local disk and kernels in Docker containers.
{
  config,
  pkgs,
  ...
}:

{
  services.marimohub = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 3000;

    settings = {
      MARIMOHUB_STORAGE_BACKEND = "fs";
      MARIMOHUB_STORAGE_FS_ROOT = "/var/lib/marimohub/storage";

      MARIMOHUB_COMPUTE_BACKEND = "docker";
      MARIMOHUB_COMPUTE_IMAGE = "ghcr.io/your-org/marimo-sandbox:latest";
      MARIMOHUB_COMPUTE_DOCKER_HOST = "localhost";
      MARIMOHUB_COMPUTE_DOCKER_BIND_HOST = "127.0.0.1";

      # The hub proxies private loopback kernel ports. Use this only for trusted
      # users: notebook code is served on the control plane's origin.
      MARIMOHUB_SANDBOX_EXPOSURE = "proxy";
      MARIMOHUB_SANDBOX_PROXY_ACK_UNTRUSTED = true;
      MARIMOHUB_APP_BASE_URL = "https://hub.example.com";

      MARIMOHUB_AUTH_BACKEND = "oidc";
      MARIMOHUB_AUTH_OIDC_ISSUER = "https://accounts.example.com";
      MARIMOHUB_AUTH_OIDC_CLIENT_ID = "marimohub";
      MARIMOHUB_AUTH_OIDC_REDIRECT_URI = "https://hub.example.com/api/auth/callback";
      MARIMOHUB_AUTH_ALLOWED_EMAIL_DOMAINS = "example.com";
      MARIMOHUB_DEFAULT_ROLE = "none";

      MARIMOHUB_RUN_MAINTENANCE = true;
    };

    # Root-owned, mode 0400; see examples/marimohub.env.example.
    environmentFiles = [ "/run/keys/marimohub.env" ];
    runtimePackages = [ pkgs.docker ];
    supplementaryGroups = [ "docker" ];
  };

  virtualisation.docker.enable = true;

  services.caddy = {
    enable = true;
    virtualHosts."hub.example.com".extraConfig = ''
      reverse_proxy 127.0.0.1:${toString config.services.marimohub.port}
    '';
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
