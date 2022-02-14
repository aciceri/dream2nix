{
  lib
,
  externals
,
  nodejs
,
  translatorName
,
  utils
,
  ...
}:
{
  translate =
    {
      inputDirectories
    ,
      inputFiles
    ,
      # extraArgs
      name
    ,
      noDev
    ,
      nodejs
    ,
      peer
    ,
      ...
    }
    @ args:
    let
      b = builtins;
      dev = !noDev;

      sourceDir = lib.elemAt inputDirectories 0;
      yarnLock = utils.readTextFile "${sourceDir}/yarn.lock";
      packageJSON = b.fromJSON (b.readFile "${sourceDir}/package.json");
      parser = import ../yarn-lock/parser.nix
      {
        inherit lib;
        inherit (externals) nix-parsec;
      };

      tryParse = parser.parseLock yarnLock;
      parsedLock =
        if tryParse.type == "success"
        then lib.foldAttrs (n: a: n // a) { } tryParse.value
        else
          let
            failureOffset = tryParse.value.offset;
          in
            throw ''
              parser failed at:
              ${lib.substring failureOffset 50 tryParse.value.str}
            '';
    in
      utils.simpleTranslate
      (
        {
          getDepByNameVer
        ,
          dependenciesByOriginalID
        ,
          ...
        }:
        rec {
          inherit translatorName;

          inputData = parsedLock;

          defaultPackage =
            if name != "{automatic}"
            then name
            else
              packageJSON.name or (
                  throw (
                    "Could not identify package name. "
                    + "Please specify extra argument 'name'"
                  )
                );

          packages."${defaultPackage}" = packageJSON.version or "unknown";

          subsystemName = "nodejs";

          subsystemAttrs = { nodejsVersion = args.nodejs; };

          mainPackageDependencies =
            lib.mapAttrsToList
            (
              depName: depSemVer: let
                depYarnKey = "${depName}@${depSemVer}";
                dependencyAttrs =
                  if !inputData ? "${depYarnKey}"
                  then throw "Cannot find entry for top level dependency: '${depYarnKey}'"
                  else inputData."${depYarnKey}";
              in
                {
                  name = depName;
                  version = dependencyAttrs.version;
                }
            )
            (
              packageJSON.dependencies or { }
              //
              packageJSON.optionalDependencies or { }
              //
              (lib.optionalAttrs dev (packageJSON.devDependencies or { }))
              //
              (lib.optionalAttrs peer (packageJSON.peerDependencies or { }))
            );

          serializePackages = inputData:
            lib.mapAttrsToList
            (yarnName: depAttrs: depAttrs // { inherit yarnName; })
            parsedLock;

          getOriginalID = dependencyObject:
            dependencyObject.yarnName;

          getName = dependencyObject:
            if lib.hasInfix "@git+" dependencyObject.yarnName
            then lib.head (lib.splitString "@git+" dependencyObject.yarnName)
            # Example:
            # @matrix-org/olm@https://gitlab.matrix.org/api/v4/projects/27/packages/npm/@matrix-org/olm/-/@matrix-org/olm-3.2.3.tgz
            else if lib.hasInfix "@https://" dependencyObject.yarnName
            then lib.head (lib.splitString "@https://" dependencyObject.yarnName)
            else
              let
                split = lib.splitString "@" dependencyObject.yarnName;
                version = lib.last split;
              in
                if lib.hasPrefix "@" dependencyObject.yarnName
                then lib.removeSuffix "@${version}" dependencyObject.yarnName
                else lib.head split;

          getVersion = dependencyObject:
            dependencyObject.version;

          getDependencies = dependencyObject: let
            dependencies =
              dependencyObject.dependencies or [ ]
              ++ dependencyObject.optionalDependencies or [ ];
          in
            lib.forEach
            dependencies
            (
              dependency:
                builtins.head (
                  lib.mapAttrsToList
                  (
                    name: versionSpec: let
                      yarnName = "${name}@${versionSpec}";
                      depObject = dependenciesByOriginalID."${yarnName}";
                      version = depObject.version;
                    in
                      if !dependenciesByOriginalID ? ${yarnName}
                      then
                        # handle missing lock file entry
                        let
                          versionMatch =
                            b.match ''.*\^([[:digit:]|\.]+)'' versionSpec;
                        in
                          {
                            inherit name;
                            version = b.elemAt versionMatch 0;
                          }
                      else { inherit name version; }
                  )
                  dependency
                )
            );

          getSourceType = dependencyObject: let
            dObj = dependencyObject;
          in
            if
              lib.hasInfix "@github:" dObj.yarnName
              || dObj
              ? resolved
              && lib.hasInfix "codeload.github.com/" dObj.resolved
              || lib.hasInfix "@git+" dObj.yarnName
              # example:
              # "jest-image-snapshot@https://github.com/machard/jest-image-snapshot#machard-patch-1":
              #   version "4.2.0"
              #   resolved "https://github.com/machard/jest-image-snapshot#d087e8683859dba2964b5866a4d1eb02ba64e7b9"
              || (
                lib.hasInfix "@https://github.com" dObj.yarnName
                && lib.hasPrefix "https://github.com" dObj.resolved
              )
            then
              if dObj ? integrity
              then
                b.trace (
                  "Warning: Using git despite integrity exists for"
                  + "${getName dObj}"
                )
                "git"
              else "git"
            else if
              lib.hasInfix "@link:" dObj.yarnName
              || lib.hasInfix "@file:" dObj.yarnName
            then "path"
            else "http";

          sourceConstructors = {
            git = dependencyObject:
              if utils.identifyGitUrl dependencyObject.resolved
              then
                (utils.parseGitUrl dependencyObject.resolved)
                // {
                  version = dependencyObject.version;
                }
              else
                let
                  githubUrlInfos = lib.splitString "/" dependencyObject.resolved;
                  owner = lib.elemAt githubUrlInfos 3;
                  repo = lib.elemAt githubUrlInfos 4;
                in
                  if b.length githubUrlInfos == 7
                  then
                    let
                      rev = lib.elemAt githubUrlInfos 6;
                    in
                      {
                        url = "https://github.com/${owner}/${repo}";
                        inherit rev;
                      }
                  else if b.length githubUrlInfos == 5
                  then
                    let
                      urlAndRev = lib.splitString "#" dependencyObject.resolved;
                    in
                      {
                        url = lib.head urlAndRev;
                        rev = lib.last urlAndRev;
                      }
                  else
                    throw (
                      "Unable to parse git dependency for: "
                      + "${getName dependencyObject}#${getVersion dependencyObject}"
                    );

            path = dependencyObject:
              if lib.hasInfix "@link:" dependencyObject.yarnName
              then
                {
                  path =
                    lib.last (lib.splitString "@link:" dependencyObject.yarnName);
                }
              else if lib.hasInfix "@file:" dependencyObject.yarnName
              then
                {
                  path =
                    lib.last (lib.splitString "@file:" dependencyObject.yarnName);
                }
              else throw "unknown path format ${b.toJSON dependencyObject}";

            http = dependencyObject: {
              type = "http";
              hash =
                if dependencyObject ? integrity
                then dependencyObject.integrity
                else
                  let
                    hash =
                      lib.last (lib.splitString "#" dependencyObject.resolved);
                  in
                    if lib.stringLength hash == 40
                    then hash
                    else throw "Missing integrity for ${dependencyObject.yarnName}";
              url = lib.head (lib.splitString "#" dependencyObject.resolved);
            };
          };

          # TODO: implement createMissingSource
          # createMissingSource = name: version:
          #   let
          #     pname = lib.last (lib.splitString "/" name);
          #   in
        }
      );

  # From a given list of paths, this function returns all paths which can be processed by this translator.
  # This allows the framework to detect if the translator is compatible with the given inputs
  # to automatically select the right translator.
  compatiblePaths =
    {
      inputDirectories
    ,
      inputFiles
    ,
    }
    @ args:
    {
      inputDirectories =
        lib.filter
        (utils.containsMatchingFile [ ''.*yarn\.lock'' ''.*package.json'' ])
        args.inputDirectories;

      inputFiles = [ ];
    };

  # If the translator requires additional arguments, specify them here.
  # There are only two types of arguments:
  #   - string argument (type = "argument")
  #   - boolean flag (type = "flag")
  # String arguments contain a default value and examples. Flags do not.
  extraArgs = {
    name = {
      description = "The name of the main package";
      examples = [
        "react"
        "@babel/code-frame"
      ];
      default = "{automatic}";
      type = "argument";
    };

    noDev = {
      description = "Exclude development dependencies";
      type = "flag";
    };

    nodejs = {
      description = "nodejs version to use for building";
      default = lib.elemAt (lib.splitString "." nodejs.version) 0;
      examples = [
        "14"
        "16"
      ];
      type = "argument";
    };

    peer = {
      description = "Include peer dependencies";
      type = "flag";
    };
  };
}
