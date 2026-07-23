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
      example = lib.literalExpression "[ pkgs.docker ]";
      description = ''
        Extra packages placed on the service PATH. Add pkgs.docker for Docker
        compute, or pkgs.uv, pkgs.python3, and pkgs.git for local development
        compute.
      '';
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
    ];

    warnings = lib.optional ((cfg.settings.MARIMOHUB_AUTH_BACKEND or null) == "dev") ''
      services.marimohub uses unauthenticated development auth. Do not expose it
      to untrusted users.
    '';

    users.groups = lib.mkIf (cfg.group == "marimohub") {
      marimohub = { };
    };

    users.users = lib.mkIf (cfg.user == "marimohub") {
      marimohub = {
        isSystemUser = true;
        inherit (cfg) group;
        home = "/var/lib/marimohub";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    systemd.services.marimohub = {
      description = "marimohub notebook hub";
      documentation = [ "https://github.com/marimo-team/marimohub" ];
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = cfg.runtimePackages;

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
        ProtectHome = true;
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
