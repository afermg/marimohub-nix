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
  dexUserType = lib.types.submodule {
    options = {
      email = lib.mkOption {
        type = lib.types.str;
        description = "Email address used to sign in through Dex.";
      };
      username = lib.mkOption {
        type = lib.types.str;
        description = "Username displayed by Dex.";
      };
      userId = lib.mkOption {
        type = lib.types.str;
        description = "Stable, non-empty Dex user identifier.";
      };
      passwordHashEnv = lib.mkOption {
        type = lib.types.strMatching "[A-Z_][A-Z0-9_]*";
        description = ''
          Name of an environment variable containing this user's bcrypt hash.
          Define it in dex.environmentFile; never put the hash directly in Nix.
        '';
      };
    };
  };
  defaultSandboxImage = pkgs.callPackage ./sandbox-image.nix { };
  podmanDevices =
    cfg.podman.devices
    ++ lib.optionals cfg.podman.nvidia.enable (
      map (device: "nvidia.com/gpu=${device}") cfg.podman.nvidia.devices
    );
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
  dexPasswordInjector = pkgs.writeScript "marimohub-dex-inject-passwords" ''
    #!${lib.getExe pkgs.python3}
    import os
    from pathlib import Path

    path = Path("/run/dex/config.yaml")
    config_text = path.read_text()
    names = ${builtins.toJSON (map (user: user.passwordHashEnv) cfg.dex.users)}
    for name in names:
        marker = "$" + name
        password_hash = os.environ.get(name, "")
        if len(password_hash) != 60 or not password_hash.startswith(("$2a$", "$2b$", "$2y$")):
            raise SystemExit(f"{name} must contain a valid 60-character bcrypt hash")
        if marker not in config_text:
            raise SystemExit(f"Dex password marker {marker} is missing")
        config_text = config_text.replace(marker, password_hash)
    path.write_text(config_text)
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

      devices = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "[^,]+");
        default = [ ];
        example = [ "/dev/zero:/dev/example-device" ];
        description = ''
          Host paths or CDI device names passed separately to `podman run
          --device` for every notebook sandbox. Prefer podman.nvidia for NVIDIA
          GPUs. Every sandbox receives every device in this list.
        '';
      };

      nvidia = {
        enable = lib.mkEnableOption "NVIDIA CDI passthrough for every notebook sandbox";

        devices = lib.mkOption {
          type = lib.types.listOf (lib.types.strMatching "[^,]+");
          default = [ "all" ];
          example = [
            "0"
            "1"
          ];
          description = ''
            NVIDIA CDI selectors. `all` exposes every GPU; numeric indices and
            GPU UUIDs can restrict the set. Each value becomes
            `nvidia.com/gpu=<value>` and is granted to every sandbox.
          '';
        };
      };
    };

    google = {
      enable = lib.mkEnableOption "direct Google OIDC authentication";

      clientId = lib.mkOption {
        type = lib.types.str;
        description = "Google OAuth web application's client ID.";
      };

      redirectUri = lib.mkOption {
        type = lib.types.str;
        example = "https://hub.example.com/api/auth/callback";
        description = "Exact callback URI registered in Google Cloud.";
      };

      environmentFile = lib.mkOption {
        type = lib.types.str;
        default = "/run/keys/marimohub-google.env";
        description = ''
          Root-readable environment file containing
          MARIMOHUB_AUTH_OIDC_CLIENT_SECRET and MARIMOHUB_AUTH_SESSION_SECRET.
        '';
      };

      allowedEmails = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "alice@example.com"
          "bob@gmail.com"
        ];
        description = ''
          Exact verified Google email addresses permitted to sign in. Use this
          for a private deployment whose invited users have different domains.
        '';
      };

      allowedEmailDomains = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "example.com" ];
        description = ''
          Verified-email domains permitted to sign in. At least one exact email
          or domain restriction is required; both restrictions apply when set.
        '';
      };
    };

    dex = {
      enable = lib.mkEnableOption "a local Dex OIDC password provider";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.dex-oidc;
        defaultText = lib.literalExpression "pkgs.dex-oidc";
        description = "Dex package to run.";
      };

      issuer = lib.mkOption {
        type = lib.types.str;
        default = "http://localhost:5556/dex";
        description = ''
          Public Dex issuer URL. The loopback HTTP default is only for local
          testing; use an HTTPS URL when exposing the service.
        '';
      };

      redirectUri = lib.mkOption {
        type = lib.types.str;
        default = "http://localhost:3000/api/auth/callback";
        description = "Absolute marimohub OIDC callback registered with Dex.";
      };

      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Address on which Dex listens.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5556;
        description = "HTTP port on which Dex listens behind the HTTPS proxy.";
      };

      clientId = lib.mkOption {
        type = lib.types.str;
        default = "marimohub";
        description = "OIDC client identifier shared by Dex and marimohub.";
      };

      environmentFile = lib.mkOption {
        type = lib.types.str;
        default = "/run/keys/marimohub-dex.env";
        description = ''
          Root-readable environment file containing
          MARIMOHUB_AUTH_OIDC_CLIENT_SECRET, MARIMOHUB_AUTH_SESSION_SECRET, and
          every bcrypt hash variable named by dex.users.
        '';
      };

      users = lib.mkOption {
        type = lib.types.listOf dexUserType;
        default = [ ];
        example = lib.literalExpression ''
          [{
            email = "alice@example.com";
            username = "alice";
            userId = "alice";
            passwordHashEnv = "DEX_ALICE_PASSWORD_HASH";
          }]
        '';
        description = "Static Dex password users. Hashes are read from the environment file.";
      };

      allowedEmailDomains = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "*" ];
        description = ''
          Email domains accepted by marimohub. The default allows every account
          in the explicit static Dex user list.
        '';
      };

      allowInsecureHttp = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Permit HTTP for loopback issuer and callback URLs. This downstream
          development option rejects non-loopback HTTP and must be false in an
          externally exposed deployment.
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
      {
        assertion = !cfg.podman.nvidia.enable || cfg.podman.enable;
        message = "services.marimohub.podman.nvidia requires podman.enable=true";
      }
      {
        assertion = !cfg.podman.nvidia.enable || cfg.podman.nvidia.devices != [ ];
        message = "services.marimohub.podman.nvidia.devices must not be empty";
      }
      {
        assertion = !(cfg.dex.enable && cfg.google.enable);
        message = "services.marimohub.dex and services.marimohub.google are mutually exclusive";
      }
      {
        assertion = !cfg.google.enable || (cfg.settings.MARIMOHUB_AUTH_BACKEND or null) == "oidc";
        message = "services.marimohub.google requires MARIMOHUB_AUTH_BACKEND=\"oidc\"";
      }
      {
        assertion =
          !cfg.google.enable || cfg.google.allowedEmails != [ ] || cfg.google.allowedEmailDomains != [ ];
        message = ''
          services.marimohub.google requires at least one allowedEmails or
          allowedEmailDomains entry so an External Google app is not open to every account.
        '';
      }
      {
        assertion = !cfg.dex.enable || cfg.dex.users != [ ];
        message = "services.marimohub.dex requires at least one static user";
      }
      {
        assertion = !cfg.dex.enable || (cfg.settings.MARIMOHUB_AUTH_BACKEND or null) == "oidc";
        message = "services.marimohub.dex requires MARIMOHUB_AUTH_BACKEND=\"oidc\"";
      }
      {
        assertion = !cfg.dex.enable || cfg.dex.allowedEmailDomains != [ ];
        message = "services.marimohub.dex.allowedEmailDomains must not be empty";
      }
    ];

    warnings =
      lib.optional ((cfg.settings.MARIMOHUB_AUTH_BACKEND or null) == "dev") ''
        services.marimohub uses unauthenticated development auth. Do not expose it
        to untrusted users.
      ''
      ++ lib.optional (cfg.dex.enable && cfg.dex.allowInsecureHttp) ''
        services.marimohub.dex uses loopback-only HTTP for local testing. Set HTTPS
        issuer/redirect URLs and dex.allowInsecureHttp=false before exposing it.
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
    hardware.nvidia-container-toolkit.enable = lib.mkIf cfg.podman.nvidia.enable true;

    services.marimohub.settings = lib.mkMerge [
      (lib.mkIf cfg.podman.enable (
        {
          MARIMOHUB_COMPUTE_BACKEND = lib.mkDefault "docker";
          MARIMOHUB_COMPUTE_IMAGE = lib.mkDefault cfg.podman.imageReference;
          MARIMOHUB_COMPUTE_DOCKER_HOST = lib.mkDefault "localhost";
          MARIMOHUB_COMPUTE_DOCKER_BIND_HOST = lib.mkDefault "127.0.0.1";
        }
        // lib.optionalAttrs (podmanDevices != [ ]) {
          MARIMOHUB_COMPUTE_DOCKER_DEVICES = lib.mkDefault (lib.concatStringsSep "," podmanDevices);
        }
      ))
      (lib.mkIf cfg.google.enable (
        {
          MARIMOHUB_AUTH_BACKEND = lib.mkDefault "oidc";
          MARIMOHUB_AUTH_OIDC_ISSUER = lib.mkDefault "https://accounts.google.com";
          MARIMOHUB_AUTH_OIDC_CLIENT_ID = lib.mkDefault cfg.google.clientId;
          MARIMOHUB_AUTH_OIDC_REDIRECT_URI = lib.mkDefault cfg.google.redirectUri;
          MARIMOHUB_AUTH_OIDC_SCOPES = lib.mkDefault "openid email";
          MARIMOHUB_DEFAULT_ROLE = lib.mkDefault "none";
        }
        // lib.optionalAttrs (cfg.google.allowedEmails != [ ]) {
          MARIMOHUB_AUTH_ALLOWED_EMAILS = lib.mkDefault (lib.concatStringsSep "," cfg.google.allowedEmails);
        }
        // lib.optionalAttrs (cfg.google.allowedEmailDomains != [ ]) {
          MARIMOHUB_AUTH_ALLOWED_EMAIL_DOMAINS = lib.mkDefault (
            lib.concatStringsSep "," cfg.google.allowedEmailDomains
          );
        }
      ))
      (lib.mkIf cfg.dex.enable {
        MARIMOHUB_AUTH_BACKEND = lib.mkDefault "oidc";
        MARIMOHUB_AUTH_OIDC_ISSUER = lib.mkDefault cfg.dex.issuer;
        MARIMOHUB_AUTH_OIDC_CLIENT_ID = lib.mkDefault cfg.dex.clientId;
        MARIMOHUB_AUTH_OIDC_REDIRECT_URI = lib.mkDefault cfg.dex.redirectUri;
        MARIMOHUB_AUTH_OIDC_ALLOW_INSECURE_HTTP = lib.mkDefault cfg.dex.allowInsecureHttp;
        MARIMOHUB_AUTH_ALLOWED_EMAIL_DOMAINS = lib.mkDefault (
          lib.concatStringsSep "," cfg.dex.allowedEmailDomains
        );
        MARIMOHUB_DEFAULT_ROLE = lib.mkDefault "none";
      })
    ];

    services.marimohub.environmentFiles = lib.mkMerge [
      (lib.mkIf cfg.google.enable [ cfg.google.environmentFile ])
      (lib.mkIf cfg.dex.enable [ cfg.dex.environmentFile ])
    ];

    services.dex = lib.mkIf cfg.dex.enable {
      enable = true;
      package = cfg.dex.package;
      environmentFile = cfg.dex.environmentFile;
      settings = {
        inherit (cfg.dex) issuer;
        storage = {
          type = "sqlite3";
          config.file = "/var/lib/dex/dex.db";
        };
        web.http = "${cfg.dex.listenAddress}:${toString cfg.dex.port}";
        oauth2.skipApprovalScreen = true;
        enablePasswordDB = true;
        staticClients = [
          {
            id = cfg.dex.clientId;
            name = "marimohub";
            secretEnv = "MARIMOHUB_AUTH_OIDC_CLIENT_SECRET";
            redirectURIs = [ cfg.dex.redirectUri ];
          }
        ];
        staticPasswords = map (user: {
          inherit (user) email username;
          userID = user.userId;
          hash = "${"$"}${user.passwordHashEnv}";
        }) cfg.dex.users;
      };
    };

    systemd.services.dex.serviceConfig = lib.mkIf cfg.dex.enable {
      StateDirectory = "dex";
      StateDirectoryMode = "0700";
      ExecStartPre = lib.mkAfter [ dexPasswordInjector ];
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
      requires =
        lib.optional cfg.podman.enable "marimohub-podman-image.service"
        ++ lib.optional cfg.podman.nvidia.enable "nvidia-container-toolkit-cdi-generator.service"
        ++ lib.optional cfg.dex.enable "dex.service";
      after = [
        "network-online.target"
      ]
      ++ lib.optional cfg.podman.enable "marimohub-podman-image.service"
      ++ lib.optional cfg.podman.nvidia.enable "nvidia-container-toolkit-cdi-generator.service"
      ++ lib.optional cfg.dex.enable "dex.service";
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
