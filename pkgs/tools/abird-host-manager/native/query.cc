// Manager-private upstream evaluator. One locked root per worker lifetime;
// queries reuse it without another fetch, lock, callFlake or evaluator.
// Consumption evidence comes from upstream fetcher/evaluator objects, never
// from evaluated flake values: the root accessor produced by InputCache for
// the exact original input must be the one mounted for callFlake.
#include "nix/cmd/common-eval-args.hh"
#include "nix/fetchers/attrs.hh"
#include "nix/fetchers/input-cache.hh"
#include "nix/expr/attr-set.hh"
#include "nix/expr/eval-inline.hh"
#include "nix/expr/value-to-json.hh"
#include "nix/flake/flake.hh"
#include "nix/flake/settings.hh"
#include "nix/main/plugin.hh"
#include "nix/main/shared.hh"
#include "nix/store/globals.hh"
#include "nix/store/store-open.hh"
#include "nix/store/worker-settings.hh"
#include "nix/util/hash.hh"
#include "nix/util/mounted-source-accessor.hh"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <memory>
#include <optional>
#include <nlohmann/json.hpp>

#define EXPORTED extern "C" __attribute__((visibility("default")))

using Callback = int (*)(const char *, size_t, void *);
constexpr size_t maxResult = 16 * 1024 * 1024;
static std::atomic<bool> used{false};
static const char * failureStage = "owned preparation failed (native-init)";

static void reportFailure() noexcept
{
    std::fputs(failureStage, stderr);
    std::fputc('\n', stderr);
}

EXPORTED unsigned int abird_owned_nix_abi() noexcept
{
    return 3;
}

EXPORTED const char * abird_owned_nix_program() noexcept
{
    return ABIRD_NIX_PROGRAM;
}

static nix::Value & field(nix::EvalState & state, nix::Value & value, const char * name)
{
    state.forceAttrs(value, nix::noPos, "while reading the owned query envelope");
    auto attr = value.attrs()->get(state.symbols.create(name));
    if (!attr)
        throw nix::Error("owned query field missing");
    return *attr->value;
}

static std::shared_ptr<nix::EvalState> evaluator(
    const std::optional<nix::Strings> & allowedUris = std::nullopt)
{
    using namespace nix;
    settings.getWorkerSettings().buildHook.setDefault(Strings{ABIRD_NIX_PROGRAM, "__build-remote"});
    initNix();
    initGC();
    flakeSettings.configureEvalSettings(evalSettings);
    evalSettings.pureEval = true;
    initPlugins();
    experimentalFeatureSettings.require(Xp::NixCommand);
    if (allowedUris) {
        evalSettings.restrictEval = true;
        evalSettings.allowedUris = *allowedUris;
    }
    auto store = openStore(StoreReference::parse("daemon"));
    return std::allocate_shared<EvalState>(
        traceable_allocator<EvalState>(), LookupPath{}, store, fetchSettings, evalSettings, store);
}

struct Session
{
    // Upstream GC roots are required: this object lives on the ordinary heap,
    // not the C++ stack or Boehm's traced heap. Destroy values before state.
    std::shared_ptr<nix::EvalState> state;
    std::unique_ptr<nix::flake::LockedFlake> locked;
    nix::RootValue root;
    std::string baseDirectory;
    nlohmann::json binding;
    std::shared_ptr<nix::SourceAccessor> rootAccessor;
    size_t queries = 0;
    bool poisoned = false;

    Session(const char * reference, const char * base)
        : baseDirectory(base)
    {
        using namespace nix;
        state = evaluator();
        auto ref = parseFlakeRef(fetchSettings, reference, baseDirectory, true);
        flake::LockFlags flags;
        flags.writeLockFile = false;
        // No in-memory relocking: unpinned/outdated inputs fail, never fetch.
        flags.updateLockFile = false;
        flags.applyNixConfig = true;
        failureStage = "owned preparation failed (native-lock)";
        locked = std::make_unique<flake::LockedFlake>(lockFlake(flakeSettings, *state, ref, flags));
        failureStage = "owned preparation failed (native-accessor)";
        binding = bind(ref);
        root = allocRootValue(state->allocValue());
        failureStage = "owned preparation failed (native-call)";
        flake::callFlake(*state, *locked, **root);
    }

    std::shared_ptr<nix::SourceAccessor> mounted(const nix::StorePath & path)
    {
        return state->storeFS->getMount(nix::CanonPath(state->store->printStorePath(path)));
    }

    // Production -> consumption: the original input's InputCache accessor is
    // the object mounted at the root path callFlake evaluates. Fails closed on
    // self-attribute refetch, registry substitution or lock changes.
    nlohmann::json bind(const nix::FlakeRef & original)
    {
        using namespace nix;
        auto produced = state->inputCache->lookup(original.input);
        if (!produced)
            throw Error("root accessor was not produced by this evaluator");
        auto & flake = locked->flake;
        auto unhashed = [](const fetchers::Input & input) {
            auto attrs = input.toAttrs();
            attrs.erase("narHash");
            return fetchers::attrsToJSON(attrs);
        };
        if (unhashed(produced->lockedInput) != unhashed(flake.lockedRef.input)
            || flake.lockedRef.input.getType() != "git" || !flake.lockedRef.input.getNarHash())
            throw Error("evaluated root input differs from produced input");
        auto rootPath = flake.path.parent();
        auto node = locked->nodePaths.find(locked->lockFile.root);
        if (node == locked->nodePaths.end() || !(node->second == rootPath))
            throw Error("evaluated root path differs");
        auto [storePath, subdir] = state->store->toStorePath(rootPath.path.abs());
        auto mount = mounted(storePath);
        if (!mount || mount.get() != produced->accessor.get_ptr().get())
            throw Error("evaluated root accessor differs from produced accessor");
        rootAccessor = mount;
        auto lockPath = flake.lockFilePath();
        auto source = lockPath.pathExists()
                          ? flake::LockFile(fetchSettings, lockPath.readFile(), lockPath.to_string())
                          : flake::LockFile();
        if (!(source == locked->lockFile) || locked->lockFile.isUnlocked(fetchSettings))
            throw Error("evaluated lock differs from source lock");
        auto info = fetchers::attrsToJSON(flake.lockedRef.input.toAttrs());
        info["outPath"] = state->store->printStorePath(storePath);
        info["dir"] = std::string(subdir.rel());
        info["lock"] =
            hashString(HashAlgorithm::SHA256, locked->lockFile.to_string().first).to_string(HashFormat::Base16, false);
        info["accessor"] = "upstream-produced";
        return info;
    }

    // Locked external flake inputs actually fetched/mounted by evaluation.
    nlohmann::json inputs()
    {
        using namespace nix;
        std::vector<std::string> names;
        auto [json, keys] = locked->lockFile.toJSON();
        for (auto & [node, key] : keys) {
            auto input = std::dynamic_pointer_cast<const flake::LockedNode>(node.get_ptr());
            if (input && mounted(input->computeStorePath(*state->store)))
                names.push_back(key);
        }
        std::sort(names.begin(), names.end());
        return names;
    }

    std::string query(const char * expression)
    {
        using namespace nix;
        failureStage = "owned preparation failed (native-expression)";
        auto function = state->allocValue();
        state->eval(state->parseExprFromString(expression, state->rootPath(baseDirectory)), *function);
        auto envelope = state->allocValue();
        state->callFunction(*function, **root, *envelope, noPos);
        NixStringContext context;
        nlohmann::json result = nlohmann::json::object();
        result["version"] = 2;
        // Selection fails before metadata; never translate evaluation errors
        // into catalog absence. Use the CLI's native no-copy serializer.
        failureStage = "owned preparation failed (native-value)";
        result["selection"] = printValueAsJSON(
            *state, true, field(*state, *envelope, "selection"), noPos, context, false);
        // Recheck the same mounted root after evaluation; no Nix value input.
        auto storePath = state->store->toStorePath(locked->flake.path.parent().path.abs()).first;
        if (!rootAccessor || mounted(storePath) != rootAccessor)
            throw Error("evaluated root accessor changed");
        result["source_info"] = binding;
        result["inputs"] = inputs();
        return result.dump();
    }
};

// One isolated inventory layer. No flake lock/probe or alternate evaluator;
// the same exact upstream no-copy JSON serializer as 'nix eval --json'.
EXPORTED int abird_owned_nix_inventory(const char * request, Callback callback, void * user) noexcept
{
    if (used.exchange(true) || !request || !callback)
        return 1;
    try {
        auto input = nlohmann::json::parse(request);
        auto state = evaluator(input.at("allowed_uris").get<nix::Strings>());
        auto expression = input.at("expression").get<std::string>();
        auto value = nix::allocRootValue(state->allocValue());
        state->eval(state->parseExprFromString(expression, state->rootPath("/var/empty")), **value);
        nix::NixStringContext context;
        auto bytes = nix::printValueAsJSON(*state, true, **value, nix::noPos, context, false).dump();
        if (bytes.size() > maxResult || callback(bytes.data(), bytes.size(), user) != 0)
            return 1;
        return 0;
    } catch (...) {
        return 1;
    }
}

EXPORTED void * abird_owned_nix_open(const char * reference, const char * base) noexcept
{
    if (used.exchange(true) || !reference || !base)
        return nullptr;
    try {
        return new Session(reference, base);
    } catch (...) {
        reportFailure();
        return nullptr;
    }
}

EXPORTED void abird_owned_nix_close(void * handle) noexcept
{
    delete static_cast<Session *>(handle);
}

EXPORTED int abird_owned_nix_query(
    void * handle, const char * expression, Callback callback, void * user) noexcept
{
    auto session = static_cast<Session *>(handle);
    if (!session || session->poisoned)
        return 1;
    // Every failure, including callback rejection, consumes this session.
    session->poisoned = true;
    // Dependencies, catalog, then derivation and activation per target (<=64).
    if (!expression || !callback || session->queries++ >= 130)
        return 1;
    try {
        auto bytes = session->query(expression);
        if (bytes.size() > maxResult || callback(bytes.data(), bytes.size(), user) != 0)
            return 1;
        session->poisoned = false;
        return 0;
    } catch (...) {
        // Native error strings can contain source credentials. Never render
        // them here; the original supervisor still owns timeout/settlement.
        reportFailure();
        return 1;
    }
}
