{ pyproject-nix, lib, ... }:

let
  inherit (pyproject-nix.lib.pep621) parseRequiresPython;
  inherit (pyproject-nix.lib.pep508) parseMarkers evalMarkers;
  inherit (pyproject-nix.lib.pypa) parseWheelFileName;
  inherit (pyproject-nix.lib) pep440;
  inherit (builtins) baseNameOf nixVersion;
  inherit (lib)
    mapAttrs
    fix
    filter
    length
    all
    groupBy
    concatMap
    attrValues
    concatLists
    genericClosure
    isAttrs
    isList
    attrNames
    typeOf
    elem
    head
    elemAt
    listToAttrs
    splitString
    nameValuePair
    optionalAttrs
    versionAtLeast
    match
    ;

  # TODO: Consider caching resolution-markers from top-level

in

fix (self: {

  /*
    Resolve dependencies from uv.lock
    .
  */
  resolveDependencies =
    {
      # Lock file as parsed by parseLock
      lock,
      # PEP-508 environment as returned by pyproject-nix.lib.pep508.mkEnviron
      environ,
      # Top-level project dependencies:
      # - as parsed by pyproject-nix.lib.pep621.parseDependencies
      # - as filtered by pyproject-nix.lib.pep621.filterDependencies
      dependencies,
    }:
    let
      # Filter dependencies of packages
      packages = map (self.filterPackage environ) (
        # Filter packages based on resolution-markers
        filter (
          pkg: length pkg.resolution-markers == 0 || all (evalMarkers environ) pkg.resolution-markers
        ) lock.package
      );

      # Group list of package candidates by package name (pname)
      candidates = groupBy (pkg: pkg.name) packages;

      # Group list of package candidates by qualified package name (pname + version)
      allCandidates = groupBy (pkg: "${pkg.name}-${pkg.version}") packages;

      # Make key return for genericClosure
      mkKey = package: {
        key = "${package.name}-${package.version}";
        inherit package;
      };

      # Filter top-level deps for genericClosure startSet
      filterTopLevelDeps =
        deps:
        map mkKey (
          concatMap (
            dep:
            filter (
              pkg: all (spec: pep440.comparators.${spec.op} pkg.version' spec.version) dep.conditions
            ) candidates.${dep.name}
          ) deps
        );

      depNames = attrNames allDependencies;

      # Resolve dependencies recursively
      allDependencies = groupBy (dep: dep.package.name) (genericClosure {
        # Recurse into top-level dependencies.
        startSet =
          filterTopLevelDeps dependencies.dependencies
          ++ filterTopLevelDeps (concatLists (attrValues dependencies.extras));

        operator =
          { key, ... }:
          # Note: Markers are already filtered.
          # Consider: Is it more efficient to only do marker filtration at resolve time, no pre-filtering?
          concatMap (
            candidate:
            map mkKey (
              concatMap (
                dep: filter (package: dep.version == null || dep.version == package.version) candidates.${dep.name}
              ) (candidate.dependencies ++ (concatLists (attrValues candidate.optional-dependencies)))
            )
          ) allCandidates.${key};
      });

      # Reduce dependency candidates down to the one resolved dependency.
      reduceDependencies =
        attrs:
        let
          result = mapAttrs (
            name: candidates:
            if isAttrs candidates then
              candidates # Already reduced
            else if length candidates == 1 then
              (head candidates).package
            # Ambigious, filter further
            else
              let
                # Get version declarations for this package from all other packages
                versions = concatMap (
                  n:
                  let
                    package = attrs.${n};
                  in
                  if isList package then
                    map (pkg: pkg.version) (
                      concatMap (pkg: filter (x: x.name == name) pkg.package.dependencies) package
                    )
                  else if isAttrs package then
                    map (pkg: pkg.version) (filter (x: x.name == name) package.dependencies)
                  else
                    throw "Unhandled type: ${typeOf package}"
                ) depNames;
                # Filter candidates by possible versions
                filtered =
                  if length versions > 0 then
                    filter (candidate: elem candidate.package.version versions) candidates
                  else
                    candidates;
              in
              filtered
          ) attrs;
          done = all isAttrs (attrValues result);
        in
        if done then result else reduceDependencies result;

    in
    reduceDependencies allDependencies;

  /*
    Filter dependencies/optional-dependencies/dev-dependencies from a uv.lock package entry
    .
  */
  filterPackage =
    environ:
    let
      filterDeps = filter (dep: dep.marker == null || evalMarkers environ dep.marker);
    in
    package:
    package
    // {
      dependencies = filterDeps package.dependencies;
      optional-dependencies = mapAttrs (_: filterDeps) package.optional-dependencies;
      dev-dependencies = mapAttrs (_: filterDeps) package.optional-dependencies;
    };

  /*
    Create a function calling buildPythonPackage based on parsed uv.lock package metadata
    .
  */
  mkPackage =
    let

      parseGitURL =
        url:
        let
          m = match "([^?]+)\\?([^#]+)#?(.*)" url;
        in
        assert m != null;
        {
          url = elemAt m 0;
          query = listToAttrs (
            map (
              s:
              let
                parts = splitString "=" s;
              in
              assert length parts == 2;
              nameValuePair (elemAt parts 0) (elemAt parts 1)
            ) (splitString "&" (elemAt m 1))
          );
          fragment = elemAt m 2;
        };

    in
    # Local pyproject.nix top-level projects (attrset)
    {
      environ,
      projects,
      workspaceRoot,
    }:
    # Parsed uv.lock package
    package:
    # Callpackage function
    {
      buildPythonPackage,
      pythonPackages,
      python,
      fetchurl,
    }:
    let
      inherit (package) source;
      isGit = source ? git;
      isProject = source ? editable;
      isPypi = source ? registry;
    in
    if isProject then
      buildPythonPackage (
        (
          if projects ? package.name then
            projects.${package.name}
          else
            pyproject-nix.lib.project.loadUVPyproject { projectRoot = workspaceRoot + "/${source.editable}"; }
        ).renderers.buildPythonPackage
          { inherit python environ; }
      )
    else
      buildPythonPackage {
        pname = package.name;
        inherit (package) version;

        pyproject = true;

        dependencies = map (dep: pythonPackages.${dep.name}) package.dependencies;
        optional-dependencies = mapAttrs (
          _: map (dep: pythonPackages.${dep.name})
        ) package.optional-dependencies;

        src =
          if isGit then
            (
              let
                parsed = parseGitURL source.git;
              in
              builtins.fetchGit (
                {
                  inherit (parsed) url;
                  rev = parsed.fragment;
                }
                // optionalAttrs (parsed ? query.tag) { ref = "refs/tags/${parsed.query.tag}"; }
                // optionalAttrs (versionAtLeast nixVersion "2.4") {
                  allRefs = true;
                  submodules = true;
                }
              )
            )
          else if isPypi then
            # TODO: Select a wheel
            fetchurl { inherit (package.sdist) url hash; }
          else
            throw "Unhandled state: could not derive src from: ${builtins.toJSON source}";
      };

  /*
    Parse unmarshaled uv.lock
    .
  */
  parseLock =
    let
      parseOptions =
        {
          resolution-mode ? null,
          exclude-newer ? null,
          prerelease-mode ? null,
        }:
        {
          inherit resolution-mode exclude-newer prerelease-mode;
        };
    in
    {
      version,
      requires-python,
      manifest ? { },
      package ? [ ],
      resolution-markers ? [ ],
      supported-markers ? [ ],
      options ? { },
    }:
    {
      inherit version;
      requires-python = parseRequiresPython requires-python;
      manifest = self.parseManifest manifest;
      package = map self.parsePackage package;
      resolution-markers = map parseMarkers resolution-markers;
      supported-markers = map parseMarkers supported-markers;
      options = parseOptions options;
    };

  parseManifest =
    {
      members ? [ ],
    }:
    {
      inherit members;
    };

  /*
    Parse a package entry from uv.lock
    .
  */
  parsePackage =
    let
      parseWheel =
        {
          url,
          hash,
          size ? null,
        }:
        {
          inherit url hash size;
          file' = parseWheelFileName (baseNameOf url);
        };

      parseMetadata =
        let
          parseRequires =
            {
              name,
              marker ? null,
              url ? null,
              path ? null,
              directory ? null,
              editable ? null,
              git ? null,
              specifier ? null,
              extras ? null,
            }:
            {
              inherit
                name
                url
                path
                directory
                editable
                git
                extras
                ;
              marker = if marker != null then parseMarkers marker else null;
              specifier = if specifier != null then pep440.parseVersionCond specifier else null;
            };
        in
        {
          requires-dist ? [ ],
          requires-dev ? { },
        }:
        {
          requires-dist = map parseRequires requires-dist;
          requires-dev = mapAttrs (_: map parseRequires) requires-dev;
        };

      parseDependency =
        {
          name,
          marker ? null,
          version ? null,
          source ? { },
        }:
        {
          inherit name source version;
          version' = if version != null then pep440.parseVersion version else null;
          marker = if marker != null then parseMarkers marker else null;

        };

    in
    {
      name,
      version,
      source,
      resolution-markers ? [ ],
      dependencies ? [ ],
      optional-dependencies ? { },
      dev-dependencies ? { },
      metadata ? { },
      wheels ? [ ],
      sdist ? { },
    }:
    {
      inherit
        name
        version
        source
        sdist
        ;
      version' = pep440.parseVersion version;
      wheels = map parseWheel wheels;
      metadata = parseMetadata metadata;
      resolution-markers = map parseMarkers resolution-markers;
      dependencies = map parseDependency dependencies;
      optional-dependencies = mapAttrs (_: map parseDependency) optional-dependencies;
      dev-dependencies = mapAttrs (_: map parseDependency) dev-dependencies;
    };
})
