{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpm_10,
  nodejs-slim_24,
  makeWrapper,
  git,
  cacert,
}:

let
  pnpm = pnpm_10.override { nodejs-slim = nodejs-slim_24; };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "marimohub";
  version = "0.1.2-unstable-2026-07-22";

  src = fetchFromGitHub {
    owner = "marimo-team";
    repo = "marimohub";
    rev = "2a510392920d8263a34eae91a0ed76393512629b";
    hash = "sha256-MYeQhwL+RjLmkXnYgyfUjK3Q19+tul73QzFGWoL8ArQ=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 4;
    hash = "sha256-hoKa4d4TAuTzSK6LuvQos9R98daZS7r+/IaAmu1IDnU=";
  };

  nativeBuildInputs = [
    pnpm
    pnpmConfigHook
    nodejs-slim_24
    makeWrapper
    git
    cacert
  ];

  env.CI = "true";

  patches = [ ./patches/local-oidc-http.patch ];

  postPatch = ''
    # Upstream currently listens on every interface. Add a downstream knob so the
    # NixOS module can default to loopback when a reverse proxy is used.
    substituteInPlace apps/server/src/index.ts \
      --replace-fail \
        'const server = serve({ fetch: app.fetch, port }, (info) => {' \
        'const hostname = process.env.MARIMOHUB_HOST ?? "0.0.0.0";
    const server = serve({ fetch: app.fetch, port, hostname }, (info) => {'
  '';

  buildPhase = ''
    runHook preBuild

    # pnpmConfigHook deliberately skips lifecycle scripts. This is the root
    # prepare script used by the upstream Docker build.
    pnpm exec vp config
    pnpm exec vp run \
      --filter @marimo-hub/web \
      --filter @marimo-hub/server \
      build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    appDir=$out/lib/marimohub
    mkdir -p "$appDir" "$out/bin" "$out/share/marimohub"
    cp -r apps/server/dist "$appDir/server"
    cp -r packages/web/dist "$out/share/marimohub/public"

    makeWrapper ${lib.getExe nodejs-slim_24} "$out/bin/marimohub" \
      --add-flags "$appDir/server/index.mjs" \
      --set-default NODE_ENV production \
      --set-default MARIMOHUB_STATIC_ROOT "$out/share/marimohub/public" \
      --set-default MARIMOHUB_VERSION "${finalAttrs.version}"

    runHook postInstall
  '';

  meta = {
    description = "Self-hostable platform for storing, managing, and running marimo notebooks";
    homepage = "https://github.com/marimo-team/marimohub";
    license = lib.licenses.asl20;
    mainProgram = "marimohub";
    platforms = lib.platforms.linux;
  };
})
