{
  bash,
  buildEnv,
  dockerTools,
  fetchFromGitHub,
  fetchpatch,
  fetchurl,
  fetchPnpmDeps,
  git,
  gnumake,
  lib,
  nodejs-slim_24,
  pkg-config,
  pnpm_10,
  pnpmConfigHook,
  poppler-utils,
  python3,
  stdenv,
  tini,
  writeText,
  managedByokProvider ? null,
}: let
  source = (import ./sources.nix).opendesign;
  pname = "opendesign";
  version = source.version;
  rev = source.rev;
  shortRev = builtins.substring 0 12 rev;
  managedByokProviderConfig =
    if managedByokProvider == null
    then null
    else {
      id = managedByokProvider.id;
      title = managedByokProvider.title;
      label = managedByokProvider.label;
      protocol = managedByokProvider.protocol;
      baseUrl = managedByokProvider.baseUrl;
      model = managedByokProvider.model;
      apiKey = managedByokProvider.apiKey or "";
      requiresApiKey = managedByokProvider.requiresApiKey or true;
    };
  managedByokProviderRevision =
    if managedByokProviderConfig == null
    then null
    else builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON managedByokProviderConfig));
  managedByokProviderPayload =
    if managedByokProviderConfig == null
    then null
    else managedByokProviderConfig // {revision = managedByokProviderRevision;};
  managedByokProviderValid =
    managedByokProviderConfig
    == null
    || (
      lib.all (value: builtins.isString value && value != "") [
        managedByokProviderConfig.id
        managedByokProviderConfig.title
        managedByokProviderConfig.label
        managedByokProviderConfig.protocol
        managedByokProviderConfig.baseUrl
        managedByokProviderConfig.model
      ]
      && builtins.elem managedByokProviderConfig.protocol [
        "anthropic"
        "openai"
        "azure"
        "google"
        "ollama"
        "senseaudio"
        "aihubmix"
      ]
    );
  managedByokProviderModule = writeText "opendesign-managed-byok-provider.ts" ''
    import type { ApiProtocol } from '../types';

    export interface ManagedByokProvider {
      revision: string;
      id: string;
      title: string;
      label: string;
      protocol: ApiProtocol;
      baseUrl: string;
      model: string;
      apiKey: string;
      requiresApiKey: boolean;
    }

    export const MANAGED_BYOK_PROVIDER = ${builtins.toJSON managedByokProviderPayload} as ManagedByokProvider | null;
  '';

  # Node 24.19.0 regressed native ObjectWrap cleanup and aborts OpenDesign's
  # better-sqlite3 statements in RemoveEnvironmentCleanupHook. Keep the pin
  # local to this image until the upstream Node fix is released and available
  # through nixpkgs. OpenSSL 3.6.4 intentionally changed empty-message CCM
  # finalization, so carry Node's upstream test compatibility fix while this
  # older runtime remains pinned.
  nodeVersion = source.node.version;
  nodejsSlim = nodejs-slim_24.overrideAttrs (old: {
    version = nodeVersion;
    src = fetchurl {
      url = "https://nodejs.org/dist/v${nodeVersion}/node-v${nodeVersion}.tar.xz";
      hash = source.node.srcHash;
    };
    patches =
      (old.patches or [])
      ++ [
        (fetchpatch {
          url = "https://github.com/nodejs/node/commit/${source.node.opensslCcmPatch.rev}.patch";
          hash = source.node.opensslCcmPatch.hash;
        })
      ];
  });
  nodejs = buildEnv {
    name = "nodejs-${nodeVersion}";
    paths = [
      nodejsSlim
      nodejsSlim.npm
      nodejsSlim.corepack
    ];
  };
  pnpmCli = "${pnpm_10}/libexec/pnpm/bin/pnpm.cjs";

  imageName = "localhost/abird/opendesign";
  imageTag = "${version}-src-${shortRev}${lib.optionalString (managedByokProviderRevision != null) "-cfg-${managedByokProviderRevision}"}";
  imageRef = "${imageName}:${imageTag}";

  src = fetchFromGitHub {
    inherit (source) owner repo;
    inherit rev;
    hash = source.srcHash;
  };

  pnpmDeps = fetchPnpmDeps {
    inherit pname src;
    hash = source.pnpmDepsHash;
    fetcherVersion = 4;
    pnpm = pnpm_10;
  };

  app = stdenv.mkDerivation {
    pname = "opendesign-app";
    inherit version src pnpmDeps;

    nativeBuildInputs = [
      gnumake
      nodejs
      pkg-config
      pnpm_10
      pnpmConfigHook
      python3
    ];

    CI = "true";
    COREPACK_ENABLE_STRICT = "0";
    NEXT_TELEMETRY_DISABLED = "1";

    patches = [./managed-byok-provider.patch];

    postPatch = ''
      cp ${managedByokProviderModule} apps/web/src/state/managed-byok-provider.ts
    '';

    buildPhase = ''
      runHook preBuild

      # pnpm's packaged launcher is tied to nixpkgs' default Node. Point
      # OpenDesign's postinstall subprocesses at pnpm's JS entrypoint so they
      # inherit the deliberately pinned runtime and its native-module ABI.
      export npm_execpath=${pnpmCli}
      export npm_config_nodedir=${nodejs}
      export npm_config_build_from_source=true

      node ./scripts/postinstall.mjs
      node "$npm_execpath" --filter @open-design/web exec vitest run tests/state/managed-byok-provider.test.ts
      node "$npm_execpath" --filter @open-design/web build
      find . -name node_modules -prune -exec rm -rf {} +
      node "$npm_execpath" install \
        --offline \
        --prod \
        --filter="@open-design/daemon..." \
        --ignore-scripts \
        --frozen-lockfile \
        --config.node-linker=hoisted \
        --config.public-hoist-pattern='*'
      test -e node_modules/zod
      test -e node_modules/@modelcontextprotocol/sdk
      (
        cd apps/daemon
        node --input-type=module -e "await import('@modelcontextprotocol/sdk/server/zod-compat.js'); await import('zod')"
      )

      test "$(node --version)" = "v${nodeVersion}"
      export PATH="${nodejs}/lib/node_modules/npm/bin/node-gyp-bin:$PATH"
      (cd node_modules/better-sqlite3 && node-gyp rebuild --release --build-from-source)
      test -f node_modules/better-sqlite3/build/Release/better_sqlite3.node

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/app/apps $out/app/apps/web
      cp -a package.json pnpm-lock.yaml pnpm-workspace.yaml node_modules packages $out/app/
      cp -a apps/daemon $out/app/apps/daemon
      cp -a apps/web/out $out/app/apps/web/out
      rm -f \
        $out/app/node_modules/.pnpm/node_modules/@open-design/desktop \
        $out/app/node_modules/.pnpm/node_modules/@open-design/e2e \
        $out/app/node_modules/.pnpm/node_modules/@open-design/landing-page \
        $out/app/node_modules/.pnpm/node_modules/@open-design/packaged \
        $out/app/node_modules/.pnpm/node_modules/@open-design/telemetry-worker

      for dir in skills design-systems craft prompt-templates; do
        cp -a "$dir" "$out/app/$dir"
      done

      cp -a data $out/app/data

      mkdir -p $out/app/assets
      cp -a assets/frames $out/app/assets/frames
      cp -a assets/community-pets $out/app/assets/community-pets

      mkdir -p $out/app/plugins
      cp -a plugins/_official $out/app/plugins/_official

      mkdir -p $out/app/.od

      runHook postInstall
    '';
  };

  imageRoot = buildEnv {
    name = "opendesign-image-root";
    paths = [
      app
      bash
      git
      nodejs
      poppler-utils
      tini
    ];
    pathsToLink = [
      "/app"
      "/bin"
    ];
  };

  image = dockerTools.buildImage {
    name = imageName;
    tag = imageTag;
    copyToRoot = imageRoot;

    config = {
      Cmd = [
        "/bin/node"
        "apps/daemon/dist/cli.js"
        "--no-open"
      ];
      Entrypoint = [
        "/bin/tini"
        "--"
      ];
      Env = [
        "NODE_ENV=production"
        "NODE_OPTIONS=--max-old-space-size=192"
        "OD_BIND_HOST=0.0.0.0"
        "OD_PORT=7456"
      ];
      ExposedPorts = {
        "7456/tcp" = {};
      };
      Labels = {
        "org.opencontainers.image.source" = "https://github.com/nexu-io/open-design";
        "org.opencontainers.image.revision" = rev;
        "org.opencontainers.image.version" = version;
      };
      User = "1001:1001";
      WorkingDir = "/app";
    };
  };
in
  assert lib.assertMsg managedByokProviderValid "OpenDesign managedByokProvider requires non-empty fields and a supported protocol";
    image
    // {
      passthru = {
        inherit imageName imageRef imageTag managedByokProviderPayload nodeVersion rev shortRev src version;
      };

      meta = {
        description = "OpenDesign container image built from pinned upstream source";
        homepage = "https://github.com/nexu-io/open-design";
        license = lib.licenses.asl20;
        platforms = lib.platforms.linux;
      };
    }
