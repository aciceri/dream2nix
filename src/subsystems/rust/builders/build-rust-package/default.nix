{...}: {
  type = "pure";

  build = {
    lib,
    pkgs,
    ...
  } @ topArgs: {
    subsystemAttrs,
    defaultPackageName,
    defaultPackageVersion,
    getCyclicDependencies,
    getDependencies,
    getSource,
    getSourceSpec,
    packages,
    produceDerivation,
    ...
  } @ args: let
    l = lib // builtins;

    utils = import ../utils.nix (args // topArgs);
    vendoring = import ../vendor.nix (args // topArgs);

    buildWithToolchain =
      utils.mkBuildWithToolchain
      (toolchain: (pkgs.makeRustPlatform toolchain).buildRustPackage);
    defaultToolchain = {
      inherit (pkgs) cargo rustc;
    };

    buildPackage = pname: version: let
      src = utils.getRootSource pname version;
      vendorDir = vendoring.vendoredDependencies;
      replacePaths = utils.replaceRelativePathsWithAbsolute {
        paths = subsystemAttrs.relPathReplacements.${pname}.${version};
      };
      writeGitVendorEntries = vendoring.writeGitVendorEntries "vendored-sources";

      cargoBuildFlags = "--package ${pname}";
    in
      produceDerivation pname (buildWithToolchain defaultToolchain {
        inherit pname version src;

        cargoBuildFlags = cargoBuildFlags;
        cargoTestFlags = cargoBuildFlags;

        cargoVendorDir = "../nix-vendor";

        postUnpack = ''
          ln -s ${vendorDir} ./nix-vendor
          export CARGO_HOME=$(pwd)/.cargo_home
        '';

        preConfigure = ''
          mkdir -p $CARGO_HOME
          if [ -f ../.cargo/config ]; then
            mv ../.cargo/config $CARGO_HOME/config.toml
          fi
          ${writeGitVendorEntries}
          ${replacePaths}
          ${utils.writeCargoLock}
        '';
      });
  in {
    packages =
      l.mapAttrs
      (name: version: {"${version}" = buildPackage name version;})
      args.packages;
  };
}
