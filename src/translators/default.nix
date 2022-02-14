{
  coreutils
,
  jq
,
  lib
,
  nix
,
  pkgs
,
  callPackageDream
,
  externals
,
  dream2nixWithExternals
,
  utils
,
  ...
}:
let
  b = builtins;

  lib = pkgs.lib;

  callTranslator = subsystem: type: name: file: args: let
    translator = callPackageDream file (
      args
      // {
        inherit externals;
        translatorName = name;
      }
    );
    translatorWithBin =
      # if the translator is a pure nix translator,
      # generate a translatorBin for CLI compatibility
      if translator ? translateBin
      then translator
      else
        translator
        // {
          translateBin = wrapPureTranslator [ subsystem type name ];
        };
  in
    translatorWithBin
    // {
      inherit subsystem type name;
      translate = args:
        translator.translate
        ((getextraArgsDefaults translator.extraArgs or { }) // args);
    };

  subsystems = utils.dirNames ./.;

  translatorTypes = [ "impure" "ifd" "pure" ];

  # adds a translateBin to a pure translator
  wrapPureTranslator = translatorAttrPath: let
    bin = utils.writePureShellScript
    [
      coreutils
      jq
      nix
    ]
    ''
      jsonInputFile=$(realpath $1)
      outputFile=$(jq '.outputFile' -c -r $jsonInputFile)

      nix eval --show-trace --impure --raw --expr "
          let
            dream2nix = import ${dream2nixWithExternals} {};
            dreamLock =
              dream2nix.translators.translators.${
      lib.concatStringsSep "." translatorAttrPath
    }.translate
                (builtins.fromJSON (builtins.readFile '''$1'''));
          in
            dream2nix.utils.dreamLock.toJSON
              # don't use nix to detect cycles, this will be more efficient in python
              (dreamLock // {
                _generic = builtins.removeAttrs dreamLock._generic [ \"cyclicDependencies\" ];
              })
      " | jq > $outputFile
    '';
  in
    bin.overrideAttrs (
      old: {
        name = "translator-${lib.concatStringsSep "-" translatorAttrPath}";
      }
    );

  # attrset of: subsystem -> translator-type -> (function subsystem translator-type)
  mkTranslatorsSet = function:
    lib.genAttrs (utils.dirNames ./.) (
      subsystem:
        lib.genAttrs
        (lib.filter (dir: builtins.pathExists (./. + "/${subsystem}/${dir}")) translatorTypes)
        (transType: function subsystem transType)
    );

  # attrset of: subsystem -> translator-type -> translator
  translators = mkTranslatorsSet (
    subsystem: type:
      lib.genAttrs (utils.dirNames (./. + "/${subsystem}/${type}")) (
        translatorName:
          callTranslator subsystem type translatorName (./. + "/${subsystem}/${type}/${translatorName}") { }
      )
  );

  # flat list of all translators
  translatorsList = lib.collect (v: v ? translateBin) translators;

  # returns the list of translators including their special args
  # and adds a flag `compatible` to each translator indicating
  # if the translator is compatible to all given paths
  translatorsForInput =
    {
      inputDirectories
    ,
      inputFiles
    ,
    }
    @ args:
      lib.forEach translatorsList
      (
        t: rec {
          inherit
            (t)
            name
            extraArgs
            subsystem
            type
            ;
          compatiblePaths = t.compatiblePaths args;
          compatible = compatiblePaths == args;
        }
      );

  # also includes subdirectories of the given paths up to a certain depth
  # to check for translator compatibility
  translatorsForInputRecursive =
    {
      inputDirectories
    ,
      depth ? 2
    ,
    }:
    let
      listDirsRec = dir: depth: let
        subDirs =
          b.map
          (subdir: "${dir}/${subdir}")
          (utils.listDirs dir);
      in
        if depth == 0
        then subDirs
        else
          subDirs
          ++
          (
            lib.flatten
            (
              map
              (subDir: listDirsRec subDir (depth - 1))
              subDirs
            )
          );

      dirsToCheck =
        inputDirectories
        ++
        (
          lib.flatten
          (
            map
            (inputDir: listDirsRec inputDir depth)
            inputDirectories
          )
        );
    in
      lib.genAttrs
      dirsToCheck
      (
        dir:
          translatorsForInput {
            inputDirectories = [ dir ];
            inputFiles = [ ];
          }
      );

  # pupulates a translators special args with defaults
  getextraArgsDefaults = extraArgsDef:
    lib.mapAttrs
    (
      name: def:
        if def.type == "flag"
        then false
        else def.default or null
    )
    extraArgsDef;
in
{
  inherit
    translators
    translatorsForInput
    translatorsForInputRecursive
    ;
}
