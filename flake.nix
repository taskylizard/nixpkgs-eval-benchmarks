{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    inherit (nixpkgs) lib;
    inherit (lib.attrsets) genAttrs;

    systems = ["x86_64-linux" "aarch64-linux"];

    forAllSystems = fn:
      genAttrs systems (
        system:
          fn (
            import nixpkgs {
              inherit system;
              config = {
                allowUnfree = true;
                allowAliases = false;
              };
            }
          )
      );

    nixVersionMap = {
      nix-git = "git";
      nix-latest = "latest";
      nix-stable = "stable";
      nix-234 = "nix_2_34";
      nix-233 = "nix_2_33";
      nix-232 = "nix_2_32";
      nix-231 = "nix_2_31";
      nix-230 = "nix_2_30";
      nix-228 = "nix_2_28";
    };

    lixVersionMap = {
      lix-git = "git";
      lix-latest = "latest";
      lix-stable = "stable";
      lix-294 = "lix_2_94";
      lix-293 = "lix_2_93";
    };
  in {
    packages = forAllSystems (
      pkgs: let
        mkPackageWithNix = _: nixVersionName: let
          eval =
            (pkgs.callPackage "${nixpkgs}/ci/eval/default.nix" {
              nix = pkgs.nixVersions.${nixVersionName};
            }) {
              chunkSize = 15000;
            };
          inherit (eval) singleSystem;
        in
          singleSystem {
            evalSystem = pkgs.stdenv.hostPlatform.system;
          };

        mkPackageWithLix = _: lixVersionName: let
          eval =
            (pkgs.callPackage "${nixpkgs}/ci/eval/default.nix" {
              nix = pkgs.lixPackageSets.${lixVersionName}.lix;
            }) {
              chunkSize = 15000;
            };
          inherit (eval) singleSystem;
        in
          singleSystem {
            evalSystem = pkgs.stdenv.hostPlatform.system;
          };
      in
        (genAttrs (builtins.attrNames nixVersionMap) (
          name:
            mkPackageWithNix name nixVersionMap.${name}
        ))
        // (genAttrs (builtins.attrNames lixVersionMap) (
          name:
            mkPackageWithLix name lixVersionMap.${name}
        ))
    );

    apps = forAllSystems (pkgs: {
      build-all = {
        type = "app";
        program = let
          script = pkgs.writeShellApplication {
            name = "build-all";
            runtimeInputs = [
              pkgs.jq
              pkgs.systemd
              pkgs.gawk
            ];
            text = ''
              set -euo pipefail

              packages=(${lib.concatStringsSep " " (builtins.attrNames self.packages.${pkgs.stdenv.hostPlatform.system})})
              rev=${lib.version}

              mkdir -p data
              nonce=$(date +%s)
              data_file="data/$nonce.json"
              jq -n --arg rev "$rev" '{"rev":($rev), "specs":{},"times":{}}' > "$data_file"


              cpu=$(awk -F: '/model name/ {print $2}' /proc/cpuinfo | head -1)
              ram_amount=$(free -b | awk '/Mem:/ {printf "%.0f", $2/1000/1024/1024}')GB
              ram_speed=$(udevadm info -e | awk '/MEMORY_DEVICE_/,/^$/ {if (/CONFIGURED_SPEED_MTS/) {split($0, a, "="); print a[2]}}' | head -1)
              ram_type=$(udevadm info -e | awk '/MEMORY_DEVICE_/,/^$/ {if (/MEMORY_DEVICE_._TYPE/) {split($0, a, "="); print a[2]}}' | head -1)

              jq \
                --arg cpu "$cpu" \
                --arg amount "$ram_amount" \
                --arg speed "$ram_speed" \
                --arg type "$ram_type" \
                '.specs += {"cpu": $cpu, "ram": {"amount": $amount, "speed": $speed, "type": $type}}' \
                "$data_file" > "$data_file.tmp"
              mv "$data_file.tmp" "$data_file"

              for package in "''${packages[@]}"; do
                echo "Building $package..."
                nix build ".#$package" --out-link "result-$package"

                total_time=$(cat result-"$package"/*/total-time)
                echo "Built $package, eval took: $total_time seconds"
                jq --arg pkg "$package" --arg time "$total_time" \
                  '.times += {($pkg): $time | tonumber}' "$data_file" > "$data_file.tmp"
                mv "$data_file.tmp" "$data_file"
              done
            '';
          };
        in
          pkgs.lib.getExe script;
      };
    });
  };
}
