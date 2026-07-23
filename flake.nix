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
      };

      packages = forAllSystems (system: {
        default = self.packages.${system}.marimohub;
        marimohub = nixpkgs.legacyPackages.${system}.callPackage ./package.nix { };
      });

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
