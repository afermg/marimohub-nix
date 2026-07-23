{
  lib,
  pkgs,
  dockerTools,
  runCommand,
  skopeo,
}:

let
  python = pkgs.python313;
  pythonEnv = python.withPackages (ps: [ ps.marimo ]);
  marimoVersion = python.pkgs.marimo.version;
  imageName = "localhost/marimohub-sandbox";
  imageTag = "py${python.pythonVersion}-marimo${marimoVersion}";
  imageReference = "${imageName}:${imageTag}";

  dockerArchive = dockerTools.buildLayeredImage {
    name = imageName;
    tag = imageTag;
    # A modest layer count keeps Podman imports quick while retaining useful
    # sharing between the largest Nix store paths.
    maxLayers = 20;

    contents = [
      pkgs.bash
      pkgs.cacert
      pkgs.coreutils
      pkgs.findutils
      pkgs.git
      pkgs.gnugrep
      pkgs.gnused
      pkgs.openssh
      pkgs.procps
      pkgs.uv
      python
      pythonEnv
    ];

    fakeRootCommands = ''
      mkdir -p ./etc ./home/appuser ./opt/venv/bin \
        ./opt/venv/lib/python${python.pythonVersion}/site-packages \
        ./tmp ./workspace/notebooks

      cat > ./etc/passwd <<'EOF'
      root:x:0:0:root:/root:/bin/sh
      appuser:x:1000:1000:marimohub sandbox:/home/appuser:/bin/sh
      EOF
      cat > ./etc/group <<'EOF'
      root:x:0:
      appuser:x:1000:
      EOF
      cat > ./opt/venv/pyvenv.cfg <<'EOF'
      home = ${python}/bin
      include-system-site-packages = false
      version = ${python.version}
      executable = ${python}/bin/python3
      EOF

      ln -s ${python}/bin/python3 ./opt/venv/bin/python
      ln -s python ./opt/venv/bin/python3
      cat > ./opt/venv/bin/marimo <<'EOF'
      #!/bin/sh
      exec /opt/venv/bin/python -m marimo "$@"
      EOF
      chmod 0755 ./opt/venv/bin/marimo

      chown -R 1000:1000 ./home/appuser ./opt/venv ./workspace
      chmod 0700 ./home/appuser
      chmod 1777 ./tmp
    '';

    config = {
      User = "1000:1000";
      WorkingDir = "/workspace/notebooks";
      Env = [
        "HOME=/home/appuser"
        "LANG=C.UTF-8"
        "MARIMO_SKIP_UPDATE_CHECK=1"
        "PATH=/opt/venv/bin:/bin"
        "PYTHONPATH=${pythonEnv}/${python.sitePackages}"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        "UV_LINK_MODE=copy"
        "UV_PROJECT_ENVIRONMENT=/opt/venv"
        "UV_PYTHON_DOWNLOADS=never"
        "VIRTUAL_ENV=/opt/venv"
        "_MARIMO_APP_OVERLOAD_AUTO_DOWNLOAD=[html]"
      ];
      Cmd = [
        "sleep"
        "infinity"
      ];
      # The adapter uses a bare `sleep infinity` as PID 1, which otherwise
      # ignores SIGTERM's default action and makes every forced removal wait.
      StopSignal = "SIGKILL";
      ExposedPorts = {
        "2718/tcp" = { };
      };
      Labels = {
        "org.opencontainers.image.description" = "Nix-built marimohub notebook sandbox";
        "org.opencontainers.image.source" = "https://github.com/afermg/marimohub-nix";
        "org.opencontainers.image.version" = imageTag;
      };
    };
  };
in
runCommand "marimohub-sandbox-${imageTag}.oci.tar"
  {
    nativeBuildInputs = [
      pkgs.gnutar
      skopeo
    ];
    passthru = {
      inherit
        dockerArchive
        imageName
        imageReference
        imageTag
        marimoVersion
        ;
    };
    meta = {
      description = "OCI archive for isolated marimohub notebook kernels";
      homepage = "https://github.com/afermg/marimohub-nix";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    };
  }
  ''
    export TMPDIR="$NIX_BUILD_TOP"
    archive="$TMPDIR/image.oci.tar"
    layout="$TMPDIR/layout"
    skopeo --tmpdir "$TMPDIR" --insecure-policy copy \
      "docker-archive:${dockerArchive}" \
      "oci-archive:$archive:${imageReference}"

    # Skopeo timestamps archive members at conversion time. Repack the completed
    # OCI layout so identical Nix inputs produce byte-identical archives.
    mkdir "$layout"
    tar -xf "$archive" -C "$layout"
    tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner \
      --format=gnu -cf "$out" -C "$layout" .
  ''
