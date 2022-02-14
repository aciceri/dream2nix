{
  lib
,
  pkgs
,
  # dream2nix
  callPackageDream
,
  translators
,
  ...
}:
let
  b = builtins;
in
rec {
  apps = {
    inherit cli contribute install;
    dream2nix = cli;
  };

  flakeApps =
    lib.mapAttrs (
      appName: app: {
        type = "app";
        program = b.toString app.program;
      }
    )
    apps;

  # the dream2nix cli
  cli = callPackageDream (import ./cli) { };

  # the contribute cli
  contribute = callPackageDream (import ./contribute) { };

  # instrall the framework to a specified location by copying the code
  install = callPackageDream (import ./install) { };
}
