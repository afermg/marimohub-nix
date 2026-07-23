{
  description = "Nix package and NixOS service for marimohub";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      overlays.default = final: _prev: {
        marimohub = final.callPackage ./package.nix { };
        marimohub-sandbox-image = final.callPackage ./sandbox-image.nix { };
      };

      packages = forAllSystems (system: {
        default = self.packages.${system}.marimohub;
        marimohub = nixpkgs.legacyPackages.${system}.callPackage ./package.nix { };
        sandbox-image = nixpkgs.legacyPackages.${system}.callPackage ./sandbox-image.nix { };
      });

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          image = self.packages.${system}.sandbox-image;
          loader = pkgs.writeShellApplication {
            name = "load-marimohub-sandbox-image";
            runtimeInputs = [ pkgs.skopeo ];
            text = ''
              exec skopeo --insecure-policy copy \
                oci-archive:${image} \
                containers-storage:${image.imageReference}
            '';
          };
        in
        {
          load-sandbox-image = {
            type = "app";
            program = nixpkgs.lib.getExe loader;
          };
        }
      );

      nixosModules = {
        default = self.nixosModules.marimohub;
        marimohub = import ./module.nix;
      };

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          package = self.packages.${system}.marimohub;
          sandbox-image = self.packages.${system}.sandbox-image;
          module = pkgs.testers.runNixOSTest {
            name = "marimohub-module";
            nodes.machine = {
              imports = [ self.nixosModules.marimohub ];
              services.marimohub = {
                enable = true;
                package = self.packages.${system}.marimohub;
                settings = {
                  MARIMOHUB_STORAGE_BACKEND = "fs";
                  MARIMOHUB_STORAGE_FS_ROOT = "/var/lib/marimohub/storage";
                  MARIMOHUB_COMPUTE_BACKEND = "none";
                  MARIMOHUB_AUTH_BACKEND = "dev";
                  MARIMOHUB_RUN_MAINTENANCE = true;
                };
              };
            };
            testScript = ''
              start_all()
              machine.wait_for_unit("marimohub.service")
              machine.wait_for_open_port(3000)
              machine.succeed("ss -ltn | grep '127.0.0.1:3000'")
              machine.fail("ss -ltn | grep '0.0.0.0:3000'")
              machine.succeed("test -d /var/lib/marimohub/storage")
              machine.succeed("curl --fail http://127.0.0.1:3000/api/health | grep '\"status\":\"ok\"'")
              machine.succeed("curl --fail http://127.0.0.1:3000/ | grep '<div id=\"root\"></div>'")
              machine.succeed("systemctl restart marimohub.service")
              machine.wait_for_open_port(3000)
              machine.succeed("curl --fail http://127.0.0.1:3000/api/health")
            '';
          };

          dex = pkgs.testers.runNixOSTest {
            name = "marimohub-dex";
            nodes.machine = {
              imports = [ self.nixosModules.marimohub ];

              environment.etc."marimohub-dex.env".text = ''
                MARIMOHUB_AUTH_OIDC_CLIENT_SECRET=dex-test-client-secret-0123456789
                MARIMOHUB_AUTH_SESSION_SECRET=session-test-secret-0123456789-abcdefghijklmnopqrstuvwxyz
                DEX_ALICE_PASSWORD_HASH=$2a$10$9S6cLl7S29wRzQoCLWideeF5uaS8siq6SiNC2Lxrz4bk0pIEzouz.
                DEX_BOB_PASSWORD_HASH=$2a$10$9S6cLl7S29wRzQoCLWideeF5uaS8siq6SiNC2Lxrz4bk0pIEzouz.
              '';

              services.marimohub = {
                enable = true;
                package = self.packages.${system}.marimohub;
                dex = {
                  enable = true;
                  environmentFile = "/etc/marimohub-dex.env";
                  users = [
                    {
                      email = "alice@example.test";
                      username = "alice";
                      userId = "alice";
                      passwordHashEnv = "DEX_ALICE_PASSWORD_HASH";
                    }
                    {
                      email = "bob@example.test";
                      username = "bob";
                      userId = "bob";
                      passwordHashEnv = "DEX_BOB_PASSWORD_HASH";
                    }
                  ];
                };
                settings = {
                  MARIMOHUB_STORAGE_BACKEND = "fs";
                  MARIMOHUB_STORAGE_FS_ROOT = "/var/lib/marimohub/storage";
                  MARIMOHUB_COMPUTE_BACKEND = "none";
                  MARIMOHUB_RUN_MAINTENANCE = true;
                };
              };
            };

            testScript = ''
              import json
              import shlex

              start_all()
              machine.wait_for_unit("dex.service")
              machine.wait_for_unit("marimohub.service")
              machine.wait_for_open_port(5556)
              machine.wait_for_open_port(3000)
              machine.succeed(
                  "curl --fail --silent "
                  "http://localhost:5556/dex/.well-known/openid-configuration"
              )

              def redirect(command):
                  url = machine.succeed(command + " -o /dev/null -w '%{redirect_url}'").strip()
                  assert url.startswith("http://localhost:"), url
                  return url

              def login(email, cookie_jar):
                  jar = shlex.quote(cookie_jar)
                  common = f"curl --silent --show-error -b {jar} -c {jar}"
                  login_url = redirect(
                      f"{common} http://localhost:3000/api/auth/login"
                  )
                  connector_url = redirect(f"{common} {shlex.quote(login_url)}")
                  form_url = redirect(f"{common} {shlex.quote(connector_url)}")
                  machine.succeed(
                      f"{common} {shlex.quote(form_url)} | grep -q 'name=\"password\"'"
                  )
                  callback_url = redirect(
                      f"{common} --data-urlencode login={shlex.quote(email)} "
                      "--data-urlencode password=correct-horse-battery-staple "
                      f"{shlex.quote(form_url)}"
                  )
                  machine.succeed(f"{common} {shlex.quote(callback_url)} -o /dev/null")
                  return json.loads(machine.succeed(
                      f"{common} http://localhost:3000/api/v1/me"
                  ))["data"]

              alice = login("alice@example.test", "/tmp/alice.cookies")
              bob = login("bob@example.test", "/tmp/bob.cookies")
              assert alice["email"] == "alice@example.test", alice
              assert bob["email"] == "bob@example.test", bob
              assert alice["id"] != bob["id"], (alice, bob)
              assert alice["logout_url"] == "/api/auth/logout", alice

              machine.succeed(
                  "curl --silent -b /tmp/alice.cookies -c /tmp/alice.cookies "
                  "http://localhost:3000/api/auth/logout -o /dev/null"
              )
              machine.succeed(
                  "test \"$(curl --silent -b /tmp/alice.cookies -o /dev/null -w '%{http_code}' "
                  "http://localhost:3000/api/v1/me)\" = 401"
              )
            '';
          };

          podman = pkgs.testers.runNixOSTest {
            name = "marimohub-podman";
            nodes.machine = {
              imports = [ self.nixosModules.marimohub ];

              virtualisation = {
                diskSize = 4096;
                memorySize = 2048;
              };

              services.marimohub = {
                enable = true;
                package = self.packages.${system}.marimohub;
                podman = {
                  enable = true;
                  image = self.packages.${system}.sandbox-image;
                  imageReference = self.packages.${system}.sandbox-image.imageReference;
                };
                settings = {
                  MARIMOHUB_STORAGE_BACKEND = "fs";
                  MARIMOHUB_STORAGE_FS_ROOT = "/var/lib/marimohub/storage";
                  MARIMOHUB_AUTH_BACKEND = "dev";
                  MARIMOHUB_RUN_MAINTENANCE = true;
                };
              };
            };

            testScript = ''
              import json
              import shlex

              start_all()
              machine.wait_for_unit("marimohub-podman-image.service")
              machine.wait_for_unit("marimohub.service")
              machine.wait_for_open_port(3000)

              uid = machine.succeed("id -u marimohub").strip()
              socket = f"unix:///run/user/{uid}/podman/podman.sock"
              remote = (
                  "runuser -u marimohub -- env HOME=/var/lib/marimohub "
                  f"podman --remote --url {socket}"
              )
              image = ${builtins.toJSON self.packages.${system}.sandbox-image.imageReference}

              machine.succeed(f"{remote} image exists {shlex.quote(image)}")
              machine.succeed(f"{remote} info --format '{{{{.Host.Security.Rootless}}}}' | grep true")

              projects = json.loads(
                  machine.succeed("curl --fail --silent http://127.0.0.1:3000/api/v1/projects")
              )
              pid = projects["data"]["items"][0]["id"]
              notebook_body = json.dumps({
                  "title": "Rootless Podman test",
                  "description": "NixOS integration test",
                  "code": "import marimo as mo\\napp = mo.App()\\nif __name__ == '__main__':\\n    app.run()\\n",
              })
              notebook = json.loads(machine.succeed(
                  "curl --fail-with-body --silent -X POST "
                  f"http://127.0.0.1:3000/api/v1/projects/{pid}/notebooks "
                  "-H 'Content-Type: application/json' --data " + shlex.quote(notebook_body)
              ))
              nid = notebook["data"]["id"]

              session = json.loads(machine.succeed(
                  "curl --fail-with-body --silent -X POST "
                  f"http://127.0.0.1:3000/api/v1/projects/{pid}/notebooks/{nid}/sessions"
              ))["data"]
              assert session["status"] == "running", session
              assert session["sandbox_url"].startswith("http://localhost:"), session

              container = machine.succeed(
                  f"{remote} ps --filter label=marimohub.sandbox --format '{{{{.Names}}}}'"
              ).strip()
              assert container.startswith("marimohub-sbx-"), container
              machine.succeed(
                  f"{remote} exec {shlex.quote(container)} sh -c "
                  + shlex.quote('test "$(id -u)" = 1000')
              )
              machine.succeed(
                  "curl --fail --silent --retry 20 --retry-connrefused "
                  + shlex.quote(session["sandbox_url"])
                  + " | grep -i marimo"
              )

              machine.succeed(
                  "curl --fail-with-body --silent -X DELETE "
                  f"http://127.0.0.1:3000/api/v1/projects/{pid}/notebooks/{nid}/sessions/"
                  + session["session_id"]
              )
              machine.wait_until_succeeds(
                  f"test -z \"$({remote} ps --filter label=marimohub.sandbox --format '{{{{.Names}}}}')\""
              )
            '';
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.nixfmt-tree
              pkgs.nil
            ];
          };
        }
      );
    };
}
