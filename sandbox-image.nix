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
  runtimeLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
  ];

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
      pkgs.stdenv.cc.cc.lib
      pkgs.uv
      pkgs.zlib
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
      cat > ./etc/profile <<'EOF'
      # NVIDIA CDI injects driver paths through either an environment variable or
      # ld.so.conf snippets. Podman exec currently drops the CDI-only variable,
      # so also recover NixOS driver store paths from the generated snippets.
      add_driver_library_path() {
        if [ -n "$NVIDIA_CTK_LIBCUDA_DIR" ]; then
          LD_LIBRARY_PATH="$NVIDIA_CTK_LIBCUDA_DIR:$LD_LIBRARY_PATH"
        fi
        for file in /etc/ld.so.conf.d/*.conf; do
          [ -r "$file" ] || continue
          while IFS= read -r directory; do
            case "$directory" in
              /nix/store/*) LD_LIBRARY_PATH="$directory:$LD_LIBRARY_PATH" ;;
            esac
          done < "$file"
        done
        export LD_LIBRARY_PATH
      }
      add_driver_library_path
      unset -f add_driver_library_path
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

      cat > ./opt/venv/bin/install-rapids-singlecell <<'EOF'
      #!/bin/sh
      set -eu
      if [ -f pyproject.toml ]; then
        exec uv add \
          'rapids-singlecell-cu13[rapids]==0.16.0' \
          'cudf-cu13==26.6.*' 'cugraph-cu13==26.6.*' 'cuml-cu13==26.6.*' \
          'cuvs-cu13==26.6.*' 'librmm-cu13==26.6.*' "$@"
      fi
      exec uv pip install --python /opt/venv/bin/python \
        'rapids-singlecell-cu13[rapids]==0.16.0' \
        'cudf-cu13==26.6.*' 'cugraph-cu13==26.6.*' 'cuml-cu13==26.6.*' \
        'cuvs-cu13==26.6.*' 'librmm-cu13==26.6.*' "$@"
      EOF
      chmod 0755 ./opt/venv/bin/install-rapids-singlecell

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
        "LD_LIBRARY_PATH=${runtimeLibraryPath}"
        "MARIMO_SKIP_UPDATE_CHECK=1"
        "PATH=/opt/venv/bin:/bin:/usr/bin"
        "PYTHONPATH=${pythonEnv}/${python.sitePackages}"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        "UV_EXTRA_INDEX_URL=https://pypi.nvidia.com"
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
