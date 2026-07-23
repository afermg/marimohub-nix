{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.marimohub;
  valueType = lib.types.oneOf [
    lib.types.str
    lib.types.int
    lib.types.bool
  ];
  stringify = value: if builtins.isBool value then lib.boolToString value else toString value;
  environment = lib.mapAttrs (_: stringify) cfg.settings;
  defaultSandboxImage = pkgs.callPackage ./sandbox-image.nix { };
  podmanAsDocker = pkgs.writeShellScriptBin "docker" ''
    runtime_dir="/run/user/$(${pkgs.coreutils}/bin/id -u)"
    # The remote client still creates a small libpod runtime directory. Keep it
    # in the service's private /tmp so /run/user can remain read-only.
    export XDG_RUNTIME_DIR="''${TMPDIR:-/tmp}/marimohub-podman"
    ${pkgs.coreutils}/bin/mkdir -p "$XDG_RUNTIME_DIR"
    ${pkgs.coreutils}/bin/chmod 0700 "$XDG_RUNTIME_DIR"
    exec ${lib.getExe cfg.podman.package} \
      --remote --url "unix://$runtime_dir/podman/podman.sock" "$@"
  '';
  podmanImageLoader = pkgs.writeShellScript "marimohub-load-podman-image" ''
    set -eu
    runtime_dir="/run/user/$(${pkgs.coreutils}/bin/id -u)"
    socket="$runtime_dir/podman/podman.sock"
    attempt=0
    while [ ! -S "$socket" ]; do
      attempt=$((attempt + 1))
      if [ "$attempt" -ge 60 ]; then
        echo "Timed out waiting for rootless Podman socket $socket" >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/sleep 1
    done
    podman_remote() {
      ${lib.getExe cfg.podman.package} --remote --url "unix://$socket" "$@"
    }
    podman_remote load --input ${lib.escapeShellArg (toString cfg.podman.image)}
    podman_remote image exists ${lib.escapeShellArg cfg.podman.imageReference}
  '';
in
{
  options.services.marimohub = {
    enable = lib.mkEnableOption "marimohub notebook hub";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.marimohub";
      description = "The marimohub package to run.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address on which marimohub listens. Keep the default when placing it
        behind a reverse proxy. This uses a small downstream MARIMOHUB_HOST patch.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "HTTP port on which marimohub listens.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the marimohub HTTP port in the firewall.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf valueType;
      default = { };
      example = lib.literalExpression ''
        {
          MARIMOHUB_STORAGE_BACKEND = "fs";
          MARIMOHUB_STORAGE_FS_ROOT = "/var/lib/marimohub/storage";
          MARIMOHUB_COMPUTE_BACKEND = "none";
          MARIMOHUB_AUTH_BACKEND = "dev";
          MARIMOHUB_RUN_MAINTENANCE = true;
        }
      '';
      description = ''
        Non-secret environment variables passed to marimohub. Attribute names
        are the upstream variable names. Boolean and integer values are converted
        to strings. Values declared here are copied to the Nix store; put secrets
        in environmentFiles instead.
      '';
    };

    environmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/run/keys/marimohub.env" ];
      description = ''
        systemd EnvironmentFile files containing secret or externally managed
        settings. Prefix a path with “-” to make it optional. Do not create these
        files through Nix store-backed declarations.
      '';
    };

    runtimePackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.uv pkgs.python3 pkgs.git ]";
      description = ''
        Extra packages placed on the service PATH. Add pkgs.uv, pkgs.python3,
        and pkgs.git for local development compute. Rootless Podman compute adds
        its Docker-compatible command automatically.
      '';
    };

    podman = {
      enable = lib.mkEnableOption "rootless Podman notebook compute";

      package = lib.mkOption {
        type = lib.types.package;
        default = config.virtualisation.podman.package;
        defaultText = lib.literalExpression "config.virtualisation.podman.package";
        description = "Podman package used by the hub and image loader.";
      };

      image = lib.mkOption {
        type = lib.types.package;
        default = defaultSandboxImage;
        defaultText = lib.literalExpression "pkgs.marimohub-sandbox-image";
        description = ''
          OCI archive loaded into the service user's rootless Podman image store.
          The default is built entirely by Nix and includes Python, uv, marimo,
          Git, and the writable environment expected by marimohub.
        '';
      };

      imageReference = lib.mkOption {
        type = lib.types.str;
        default = defaultSandboxImage.imageReference;
        defaultText = lib.literalExpression ''
          "localhost/marimohub-sandbox:<python-and-marimo-version>"
        '';
        description = ''
          Image name used by marimohub after loading podman.image. Override this
          together with podman.image when supplying another archive.
        '';
      };
    };

    supplementaryGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "docker" ];
      description = ''
        Additional groups for the service account. Docker compute normally needs
        the docker group; access to the Docker socket is root-equivalent.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "marimohub";
      description = "User under which the service runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "marimohub";
      description = "Group under which the service runs.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          !(
            cfg.openFirewall
            && lib.elem cfg.listenAddress [
              "127.0.0.1"
              "::1"
              "localhost"
            ]
          );
        message = "services.marimohub.openFirewall has no effect with a loopback listenAddress";
      }
      {
        assertion = !cfg.podman.enable || (cfg.settings.MARIMOHUB_COMPUTE_BACKEND or null) == "docker";
        message = ''
          services.marimohub.podman requires MARIMOHUB_COMPUTE_BACKEND="docker";
          this is the name of marimohub's Docker-compatible container adapter.
        '';
      }
    ];

    warnings = lib.optional ((cfg.settings.MARIMOHUB_AUTH_BACKEND or null) == "dev") ''
      services.marimohub uses unauthenticated development auth. Do not expose it
      to untrusted users.
    '';

    users.groups = lib.mkIf (cfg.group == "marimohub") {
      marimohub = { };
    };

    users.users = lib.mkMerge [
      (lib.mkIf (cfg.user == "marimohub") {
        marimohub = {
          isSystemUser = true;
          inherit (cfg) group;
          home = "/var/lib/marimohub";
        };
      })
      (lib.mkIf cfg.podman.enable {
        ${cfg.user} = {
          autoSubUidGidRange = true;
          linger = true;
        };
      })
    ];

    virtualisation.podman.enable = lib.mkIf cfg.podman.enable true;

    services.marimohub.settings = lib.mkIf cfg.podman.enable {
      MARIMOHUB_COMPUTE_BACKEND = lib.mkDefault "docker";
      MARIMOHUB_COMPUTE_IMAGE = lib.mkDefault cfg.podman.imageReference;
      MARIMOHUB_COMPUTE_DOCKER_HOST = lib.mkDefault "localhost";
      MARIMOHUB_COMPUTE_DOCKER_BIND_HOST = lib.mkDefault "127.0.0.1";
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    systemd.services.marimohub-podman-image = lib.mkIf cfg.podman.enable {
      description = "Load the marimohub sandbox image into rootless Podman";
      documentation = [ "https://github.com/afermg/marimohub-nix" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "systemd-user-sessions.service"
      ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = podmanImageLoader;
        User = cfg.user;
        Group = cfg.group;
        Environment = "HOME=/var/lib/marimohub";
        StateDirectory = "marimohub";
        StateDirectoryMode = "0750";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "2s";
        TimeoutStartSec = "120s";
        UMask = "0077";

        CapabilityBoundingSet = "";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [ "AF_UNIX" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
      };
    };

    systemd.services.marimohub = {
      description = "marimohub notebook hub";
      documentation = [ "https://github.com/marimo-team/marimohub" ];
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      requires = lib.optional cfg.podman.enable "marimohub-podman-image.service";
      after = [
        "network-online.target"
      ]
      ++ lib.optional cfg.podman.enable "marimohub-podman-image.service";
      path = cfg.runtimePackages ++ lib.optional cfg.podman.enable podmanAsDocker;

      environment = environment // {
        HOME = "/var/lib/marimohub";
        NODE_ENV = "production";
        PORT = toString cfg.port;
        MARIMOHUB_HOST = cfg.listenAddress;
        MARIMOHUB_STATIC_ROOT = "${cfg.package}/share/marimohub/public";
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = lib.getExe cfg.package;
        User = cfg.user;
        Group = cfg.group;
        SupplementaryGroups = cfg.supplementaryGroups;
        EnvironmentFile = cfg.environmentFiles;
        WorkingDirectory = "/var/lib/marimohub";
        StateDirectory = "marimohub";
        StateDirectoryMode = "0750";
        CacheDirectory = "marimohub";
        CacheDirectoryMode = "0750";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStopSec = "30s";
        UMask = "0077";

        CapabilityBoundingSet = "";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        # Rootless Podman's API socket lives below /run/user. Keep home trees
        # read-only rather than hidden when the hub must connect to that socket.
        ProtectHome = if cfg.podman.enable then "read-only" else true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
      };
    };
  };
}
