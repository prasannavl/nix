# Declared source closures only: Cargo still resolves features, roles and units.
# `workspace` is the parsed ROOT Cargo.toml; `members` maps normalized relative
# directories to parsed Cargo.tomls. Pure callers attest regular local paths and
# absence of extra local inputs; use `plan { src = ...; }` for filesystem checks.
let
  inherit (builtins) all any attrNames concatLists elem filter foldl' isAttrs isList isString length map;
  unique = xs:
    attrNames (builtins.listToAttrs (map (x: {
        name = x;
        value = true;
      })
      xs));
  concatMap = f: xs: concatLists (map f xs);
  attrs = x:
    if isAttrs x
    then x
    else {};
  strings = x: isList x && all isString x;
  reason = code: location: {inherit code location;};
  when = test: code: location:
    if test
    then [(reason code location)]
    else [];
  glob = s: builtins.replaceStrings ["*" "?" "[" "]"] ["" "" "" ""] s != s;
  dependencyFlagErrors = location: value: let
    obj = attrs value;
  in
    when (any (key: obj ? ${key} && !builtins.isBool obj.${key}) ["optional" "default-features"])
    "invalid-dependency-flag"
    location;
  # Do not clamp '..' at the root. Once traversal leaves the workspace it is
  # unsafe, even if later components would appear to bring it back inside.
  normalize = s:
    if !isString s || s == "" || builtins.match "(/.*|[A-Za-z]:.*|.*\\\\.*)" s != null
    then null
    else let
      parts = filter isString (builtins.split "/" s);
      result = foldl' (acc: part:
        if acc == null
        then null
        else if part == "" || part == "."
        then acc
        else if part == ".."
        then
          if acc == []
          then null
          else builtins.genList (i: builtins.elemAt acc i) (length acc - 1)
        else acc ++ [part]) []
      parts;
    in
      if result == null
      then null
      else if result == []
      then "."
      else builtins.concatStringsSep "/" result;
  groups = ["dependencies" "build-dependencies" "dev-dependencies"];
  # Older Cargo editions accept these deprecated aliases. They are outside the
  # modeled table grammar; ignoring them could silently omit path dependencies.
  underscoreTableErrors = location: manifest:
    concatMap (name:
      when ((attrs manifest) ? ${name}) "underscore-dependency-table-unsupported" "${location}.${name}")
    ["build_dependencies" "dev_dependencies"];
  tables = location: manifest:
    map (kind: {
      location = "${location}.${kind}";
      value = manifest.${kind} or {};
    })
    groups
    ++ concatMap (target:
      map (kind: {
        location = "${location}.target.${target}.${kind}";
        value = (attrs manifest.target.${target}).${kind} or {};
      })
      groups) (attrNames (attrs (manifest.target or {})));
  entries = table:
    map (alias: {
      inherit alias;
      location = "${table.location}.${alias}";
      value = table.value.${alias};
    }) (attrNames (attrs table.value));
  declarations = dir: rootDeps: manifest:
    concatMap (table:
      map (entry: let
        inherited = isAttrs entry.value && (entry.value.workspace or false) == true;
        base =
          if inherited
          then rootDeps.${entry.alias} or null
          else entry.value;
      in
        entry
        // {
          value = base;
          owner = dir;
          origin =
            if inherited
            then "."
            else dir;
          errors =
            when (inherited && base == null) "missing-workspace-dependency" entry.location
            ++ (
              if inherited
              then dependencyFlagErrors entry.location entry.value
              else []
            )
            ++ when (isAttrs entry.value
              && entry.value ? workspace
              && entry.value.workspace != true) "invalid-workspace-inheritance"
            entry.location
            ++ when (inherited && any (key: entry.value ? ${key}) ["path" "package" "git" "version"])
            "workspace-dependency-override"
            entry.location;
        }) (entries table)) (tables dir manifest);
  # A directory closure cannot silently omit manifest-directed files outside
  # that package directory. Arbitrary build-script effects are not modeled.
  extraPaths = dir: manifest: let
    package = attrs (manifest.package or {});
    values =
      map (key: package.${key} or false) ["build" "readme" "license-file"]
      ++ [(attrs (manifest.lib or {})).path or false]
      ++ concatMap (kind:
        map (target: (attrs target).path or false)
        (
          if isList (manifest.${kind} or [])
          then manifest.${kind} or []
          else []
        ))
      ["bin" "example" "test" "bench"];
  in
    concatMap (p: when (isString p && normalize p == null) "additional-manifest-input" dir) values;
  manifestErrors = dir: manifest:
    when (!isAttrs manifest) "invalid-manifest" dir
    ++ underscoreTableErrors dir manifest
    ++ when (manifest ? patch) "patch-unsupported" dir
    ++ when (manifest ? replace) "replace-unsupported" dir
    ++ when (manifest ? workspace && dir != ".") "nested-workspace" dir
    ++ when (!isAttrs (manifest.target or {})) "invalid-target-table" dir
    ++ concatMap (target: when (!isAttrs manifest.target.${target}) "invalid-target-table" "${dir}.${target}")
    (attrNames (attrs (manifest.target or {})))
    ++ concatMap (target: underscoreTableErrors "${dir}.target.${target}" manifest.target.${target})
    (attrNames (attrs (manifest.target or {})))
    ++ concatMap (table: when (!isAttrs table.value) "invalid-dependency-table" table.location)
    (tables dir manifest);
  # Root declarations and scope are checked without touching member values or
  # paths. The filesystem adapter and pure planner share this single policy.
  rootTopology = {
    workspace,
    memberDirs ? null,
  } @ args: let
    root = attrs workspace;
    ws = attrs (root.workspace or {});
    scoped = args ? memberDirs;
    declared = ws.members or [];
    declaredDirs = unique (filter (d: isString d && normalize d == d && !glob d) (
      if isList declared
      then declared
      else []
    ));
    dirs =
      if !scoped
      then declaredDirs
      else
        unique (filter (d: isString d && normalize d == d && !glob d && elem d declaredDirs)
          (
            if isList memberDirs
            then memberDirs
            else []
          ));
    scopeErrors =
      when (scoped && (!strings memberDirs || memberDirs == [])) "invalid-source-scope" "memberDirs"
      ++ (
        if scoped && isList memberDirs
        then
          when (length (filter isString memberDirs) != length (unique (filter isString memberDirs)))
          "duplicate-source-scope-member" "memberDirs"
          ++ concatMap (d:
            if !isString d
            then []
            else
              when (normalize d != d || glob d) "noncanonical-source-scope-member" d
              ++ when (!elem d declaredDirs) "undeclared-source-scope-member" d)
          memberDirs
        else []
      );
    errors =
      when (!isAttrs workspace) "invalid-input" "."
      ++ scopeErrors
      ++ when (!(root ? workspace) || !isAttrs root.workspace) "invalid-workspace" "."
      ++ when (!(ws ? members) || !strings declared) "explicit-members-required" "workspace.members"
      ++ concatMap (d:
        when (!isString d) "invalid-member" "workspace.members"
        ++ (
          if isString d
          then
            when (glob d) "member-glob" d
            ++ when (normalize d == null) "member-outside-workspace" d
            ++ when (normalize d != null && normalize d != d) "member-not-normalized" d
          else []
        ))
      (
        if isList declared
        then declared
        else []
      )
      # Parent member sources would currently include nested peers' files.
      ++ concatMap (d:
        when (any (parent: let
          prefix = "${parent}/";
        in
          parent
          != "."
          && parent != d
          && builtins.substring 0 (builtins.stringLength prefix) d == prefix)
        declaredDirs)
        "overlapping-member-directories"
        d)
      declaredDirs
      ++ when ((ws.exclude or []) != []) "workspace-excludes" "workspace.exclude"
      ++ when ((ws.default-members or []) != []) "workspace-default-members" "workspace.default-members"
      ++ when (any (key: (attrs (ws.package or {})) ? ${key}) ["readme" "license-file"])
      "additional-workspace-input" "workspace.package"
      ++ when (!isAttrs (ws.dependencies or {})) "invalid-dependency-table" "workspace.dependencies"
      ++ underscoreTableErrors "workspace" ws
      ++ when (root ? package || elem "." declaredDirs) "root-package-filter-unsupported" "."
      ++ when (any (key: root ? ${key}) groups) "root-package-dependencies-unsupported" "."
      ++ manifestErrors "." root;
  in {
    inherit root ws scoped declaredDirs dirs errors;
  };
  analyze = {
    workspace,
    members,
    additionalInputs ? [],
    memberDirs ? null,
  } @ args: let
    topology = rootTopology ({inherit workspace;}
      // (
        if args ? memberDirs
        then {inherit memberDirs;}
        else {}
      ));
    inherit (topology) root ws scoped declaredDirs dirs;
    supplied =
      if !scoped
      then attrs members
      else
        builtins.intersectAttrs (builtins.listToAttrs (map (d: {
            name = d;
            value = true;
          })
          dirs)) (attrs members);
    rootDeps = attrs (ws.dependencies or {});
    # Inspect root declarations too: even unused workspace path dependencies
    # can require local manifests during Cargo resolution of a filtered root.
    deps =
      concatMap (d: declarations d rootDeps (attrs (supplied.${d} or {}))) dirs
      ++ map (entry:
        entry
        // {
          origin = ".";
          owner = ".";
          errors = [];
        })
      (entries {
        location = "workspace.dependencies";
        value = rootDeps;
      });
    inspect = dep: let
      value = dep.value;
      obj = attrs value;
      hasPath = obj ? path;
      resolved =
        if hasPath && isString obj.path
        then normalize "${dep.origin}/${obj.path}"
        else null;
      # Absolute paths must be rejected before adding a relative origin.
      validPath =
        hasPath
        && isString obj.path
        && obj.path != ""
        && builtins.match "(/.*|[A-Za-z]:.*|.*\\\\.*)" obj.path == null;
      # A path may normalize to an admitted target after traversing an omitted
      # peer (peer/../selected). Never probe that peer, even to check symlinks.
      admittedPath = p:
        p
        == "."
        || any (d:
          p
          == d
          || builtins.substring 0 (builtins.stringLength "${d}/") p == "${d}/"
          || builtins.substring 0 (builtins.stringLength "${p}/") d == "${p}/")
        dirs;
      route =
        if !scoped || !validPath || resolved == null
        then {safe = true;}
        else
          foldl' (acc: part: let
            p = normalize "${acc.path}/${part}";
          in {
            path = p;
            safe = acc.safe && p != null && admittedPath p;
          }) {
            path = ".";
            safe = true;
          }
          (filter isString (builtins.split "/" "${dep.origin}/${obj.path}"));
      expected = obj.package or dep.alias;
      actual = (attrs ((attrs (supplied.${resolved} or {})).package or {})).name or null;
    in {
      path =
        if validPath && resolved != null && (!scoped || elem resolved dirs) && route.safe
        then "${dep.origin}/${obj.path}"
        else null;
      edge =
        if
          hasPath
          && validPath
          && resolved != null
          && elem resolved dirs
          && isString expected
          && actual == expected
        then {
          from = dep.owner;
          to = resolved;
        }
        else null;
      errors =
        dep.errors
        ++ when (!(isString value || isAttrs value)) "invalid-dependency" dep.location
        ++ when (obj ? package && !isString obj.package) "invalid-package-name" dep.location
        ++ dependencyFlagErrors dep.location obj
        ++ when (any (key: obj ? ${key} && !isString obj.${key}) ["version" "registry" "registry-index" "git"])
        "invalid-dependency-source"
        dep.location
        ++ when (obj ? workspace) "invalid-workspace-dependency" dep.location
        ++ when (hasPath && !isString obj.path) "invalid-path" dep.location
        ++ when (hasPath && (!validPath || resolved == null)) "path-outside-workspace" dep.location
        # Registry/version fields can describe publication's alternate location.
        ++ when (hasPath && obj ? git)
        "conflicting-path-source"
        dep.location
        ++ when (scoped && validPath && resolved != null && elem resolved dirs && !route.safe)
        "dependency-route-outside-source-scope"
        dep.location
        ++ when (scoped && hasPath && validPath && resolved != null && !elem resolved dirs)
        "path-outside-source-scope"
        dep.location
        ++ when (hasPath && validPath && resolved != null && !elem resolved declaredDirs)
        "nonmember-path-dependency"
        dep.location
        ++ when (hasPath && validPath && elem resolved dirs && actual != expected)
        "path-package-name-mismatch"
        dep.location;
    };
    inspected = map inspect deps;
    errors =
      if topology.errors != []
      then topology.errors
      else
        when (!isAttrs members) "invalid-input" "."
        ++ when (!isList additionalInputs || additionalInputs != []) "additional-local-inputs" "."
        ++ concatMap (d:
          when (!elem d dirs) "undeclared-member-manifest" d
          ++ when (normalize d != d || glob d) "member-key-not-normalized" d) (attrNames supplied)
        ++ concatMap (d: let
          m = attrs (supplied.${d} or {});
          p = attrs (m.package or {});
        in
          when (!(supplied ? ${d})) "missing-member-manifest" d
          ++ manifestErrors d (supplied.${d} or {})
          ++ extraPaths d m
          ++ when (!isAttrs (m.package or null) || !isString (p.name or null)) "invalid-member-package" d
          ++ when (p ? workspace) "package-workspace-override" d)
        dirs
        ++ concatMap (x: x.errors) inspected;
    adjacency = builtins.listToAttrs (map (d: {
        name = d;
        value =
          unique (map (x: x.edge.to)
            (filter (x: x.edge != null && x.edge.from == d) inspected));
      })
      dirs);
    reach = graph: start: let
      go = seen: pending:
        if pending == []
        then unique seen
        else let
          d = builtins.head pending;
          rest = builtins.tail pending;
        in
          if elem d seen
          then go seen rest
          else go (seen ++ [d]) (rest ++ graph.${d});
    in
      go [] [start];
    closures = builtins.mapAttrs (d: _: reach adjacency d) adjacency;
    undirected = builtins.mapAttrs (d: ds: unique (ds ++ filter (p: elem d adjacency.${p}) dirs)) adjacency;
    components = foldl' (acc: d:
      if any (c: elem d c) acc
      then acc
      else acc ++ [(reach undirected d)]) []
    dirs;
    parentCandidates = builtins.mapAttrs (d: closure:
      builtins.sort (a: b: let
        sa = length closures.${a};
        sb = length closures.${b};
      in
        if sa == sb
        then a < b
        else sa > sb)
      (filter (p: length closures.${p} < length closure && all (x: elem x closure) closures.${p}) dirs))
    closures;
    planData = {
      members = dirs;
      pathDeps = adjacency;
      closureDirs = closures;
      inherit components parentCandidates;
    };
  in {
    kind = "declared-source-closures";
    supported = errors == [];
    reasons = errors;
    # Never expose an incomplete graph as a usable plan.
    plan =
      if errors == []
      then planData
      else null;
    metadata =
      {
        rootPackage = root ? package;
        workspaceDependencies = ws ? dependencies;
        patch = root ? patch;
        replace = root ? replace;
        filesystemChecked = false;
      }
      // (
        if !scoped
        then {}
        else {
          # This proves closure only inside the selected workspace, not absence of
          # incoming edges from omitted members. The REV generator owns that proof.
          sourceScope = {
            kind = "closed-selected-workspace";
            memberDirs = dirs;
            declaredMemberDirs = declaredDirs;
            properSubset = dirs != declaredDirs;
          };
        }
      );
    inputPaths = filter (p: p != null) (map (x: x.path) inspected);
  };
  planFromManifests = args: builtins.removeAttrs (analyze args) ["inputPaths"];
  # Evaluator-visible source only. No fromTOML tryEval: Nix parse/read errors
  # are not reliably catchable and intentionally throw (fail closed).
  readWorkspace = {
    src,
    memberDirs ? null,
  } @ args: let
    scopeArgs =
      if args ? memberDirs
      then {inherit memberDirs;}
      else {};
    rootKind =
      if builtins.isPath src && !builtins.hasContext (toString src)
      then (builtins.readDir (builtins.dirOf src)).${builtins.baseNameOf src} or null
      else throw "rust-closures: src must be an evaluator-visible path, not a derived source";
    rootEntries =
      if rootKind == "symlink"
      then {}
      else builtins.readDir src;
    pathIssue = path: let
      parts = filter (s: isString s && s != "") (builtins.split "/" path);
      go = base: ps:
        if ps == []
        then null
        else let
          p = builtins.head ps;
          kind = (builtins.readDir base).${p} or null;
        in
          if kind == "symlink"
          then "symlink-source-path"
          else if p == "."
          then go base (builtins.tail ps)
          else if p == ".."
          then go (base + "/..") (builtins.tail ps)
          else if kind == "directory"
          then go (base + "/${p}") (builtins.tail ps)
          else if kind == "regular" && builtins.tail ps == []
          then null
          else "missing-source-path";
    in
      go src parts;
    workspace = builtins.fromTOML (builtins.readFile (src + "/Cargo.toml"));
    topology = rootTopology ({inherit workspace;} // scopeArgs);
    # No selected or omitted tree is probed until root topology is supported.
    # This also excludes '.' without another copy of canonical-member rules.
    safeDirs = topology.dirs;
    members = builtins.listToAttrs (concatMap (d:
      if pathIssue "${d}/Cargo.toml" != null
      then []
      else [
        {
          name = d;
          value = builtins.fromTOML (builtins.readFile (src + "/${d}/Cargo.toml"));
        }
      ])
    safeDirs);
    preliminary = analyze ({inherit workspace members;} // scopeArgs);
    # Check member trees for symlinks/config without following symlinks. This
    # adapter is for small explicit source trees, not derived sources.
    scan = rel: let
      listing = builtins.readDir (src + "/${rel}");
    in
      concatMap (name: let
        p = "${rel}/${name}";
        kind = listing.${name};
      in
        when (kind == "symlink") "symlink-source-path" p
        ++ when (name == ".cargo") "local-cargo-config" p
        ++ (
          if kind == "directory" && name != ".cargo"
          then scan p
          else []
        )) (attrNames listing);
    ancestors = d: let
      go = p:
        if p == "."
        then ["."]
        else [p] ++ go (builtins.dirOf p);
    in
      go d;
    fsErrors =
      when (rootEntries ? ".cargo") "local-cargo-config" ".cargo"
      ++ when (args ? memberDirs && rootEntries ? ".gitignore" && rootEntries.".gitignore" != "regular")
      "nonregular-source-gitignore" ".gitignore"
      ++ when (rootEntries ? "Cargo.lock" && rootEntries."Cargo.lock" != "regular")
      (
        if rootEntries."Cargo.lock" == "symlink"
        then "symlink-source-path"
        else "nonregular-cargo-lock"
      )
      "Cargo.lock"
      ++ concatMap (d:
        if pathIssue d != null
        then [(reason (pathIssue d) d)]
        else scan d)
      safeDirs
      ++ concatMap (p:
        when (pathIssue p != null)
        (
          if pathIssue p == "symlink-source-path"
          then "symlink-dependency-path"
          else "missing-dependency-path"
        )
        p)
      preliminary.inputPaths
      ++ concatMap (d:
        concatMap (p:
          when (builtins.pathExists (src + "/${p}/.cargo")) "local-cargo-config" "${p}/.cargo")
        (ancestors d)) (filter (d: pathIssue d == null) safeDirs);
  in
    if (rootEntries."Cargo.toml" or null) != "regular"
    then
      {
        workspace.workspace.members = [];
        members = {};
        additionalInputs = [
          (reason
            (
              if rootKind == "symlink" || (rootEntries."Cargo.toml" or null) == "symlink"
              then "symlink-source-path"
              else "missing-root-manifest"
            )
            "Cargo.toml")
        ];
      }
      // scopeArgs
    else if topology.errors != []
    then
      {
        workspace = workspace;
        members = {};
        additionalInputs = [];
      }
      // scopeArgs
    else
      {
        inherit workspace members;
        additionalInputs = fsErrors;
      }
      // scopeArgs;
in {
  inherit planFromManifests readWorkspace;
  plan = args: let
    inputs = readWorkspace args;
    result = planFromManifests inputs;
  in
    result
    // {
      reasons = result.reasons ++ inputs.additionalInputs;
      metadata = result.metadata // {filesystemChecked = true;};
    };
}
