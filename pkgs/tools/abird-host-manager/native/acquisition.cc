// Caller-side signed import, never evaluation/realisation. One bounded helper
// owns temporary roots / GC exclusion through durable roots and local verification.
#include "nix/main/shared.hh"
#include "nix/store/globals.hh"
#include "nix/store/keys.hh"
#include "nix/store/local-fs-store.hh"
#include "nix/store/indirect-root-store.hh"
#include "nix/store/pathlocks.hh"
#include "nix/util/file-system.hh"
#include "nix/util/archive.hh"
#include "nix/util/git.hh"
#include "nix/util/posix-source-accessor.hh"
#include "nix/store/references.hh"
#include "nix/store/store-open.hh"
#include "nix/util/hash.hh"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <memory>
#include <optional>
#include <cstring>
#include <cstdint>
#include <filesystem>
#include <map>
#include <fcntl.h>
#include <nlohmann/json.hpp>
#include <sys/stat.h>
#include <unistd.h>

#define EXPORTED extern "C" __attribute__((visibility("default")))
using Json = nlohmann::json;
using Callback = int (*)(const char *, size_t, void *);
namespace fs = std::filesystem;
static std::atomic<bool> used{false};
static constexpr size_t maxPaths = 32768;
static constexpr size_t maxReferences = 131072;
static constexpr size_t maxRoots = 1024;

EXPORTED unsigned int abird_owned_acquisition_abi() noexcept { return 3; }
EXPORTED const char * abird_owned_acquisition_program() noexcept { return ABIRD_NIX_PROGRAM; }

static void require(bool condition)
{
    if (!condition) throw nix::Error("owned acquisition evidence differs");
}

static nix::PublicKeys trustedPublicKeys()
{
    // getDefaultPublicKeys also opens secret-key-files. Acquisition needs only
    // configured public trust and must never read a signing key.
    nix::PublicKeys keys;
    for (const auto & text : nix::settings.trustedPublicKeys.get()) {
        nix::PublicKey key(text);
        keys.emplace(key.name, key);
    }
    return keys;
}

static void directory(const fs::path & path, bool sync)
{
    int fd = open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    require(fd >= 0);
    struct stat st;
    bool valid = fstat(fd, &st) == 0 && st.st_uid == geteuid() && (st.st_mode & 07777) == 0700;
    if (valid && sync) valid = fsync(fd) == 0;
    close(fd);
    require(valid);
}

static bool rootExists(const fs::path & root, const std::string & target)
{
    auto status = fs::symlink_status(root);
    if (status.type() == fs::file_type::not_found) return false;
    struct stat st;
    require(lstat(root.c_str(), &st) == 0 && st.st_uid == geteuid()
        && fs::is_symlink(status) && fs::read_symlink(root) == fs::path(target));
    return true;
}

static void checkRoots(const fs::path & roots, const std::vector<std::string> & paths)
{
    directory(roots.parent_path().parent_path(), false);
    directory(roots.parent_path(), false);
    directory(roots, false);
    size_t count = 0;
    for (const auto & entry : fs::directory_iterator(roots)) {
        require(++count <= paths.size());
        auto name = entry.path().filename().string();
        size_t index = std::stoul(name);
        require(index < paths.size() && name == std::to_string(index));
        require(rootExists(entry.path(), paths[index]));
    }
}

static void matches(nix::Store & store, const nix::ValidPathInfo & info, const Json & expected)
{
    require(info.storeDir == "/nix/store" && info.narSize > 0
        && info.narHash.algo == nix::HashAlgorithm::SHA256);
    auto actual = info.toJSON(&store, true, nix::PathInfoJsonFormat::V1);
    for (const char * field : {"narHash", "narSize", "references", "ca"})
        require(actual.value(field, Json()) == expected.value(field, Json()));
}

struct CheckedNar : nix::Sink
{
    nix::HashSink hash{nix::HashAlgorithm::SHA256};
    uint64_t remaining;
    explicit CheckedNar(uint64_t bytes) : remaining(bytes) {}
    void operator()(std::string_view bytes) override
    {
        require(bytes.size() <= remaining);
        remaining -= bytes.size();
        hash(bytes);
    }
};

// Same upstream signed import primitive used by copyStorePath, but freeze the
// authenticated metadata instead of letting copyPaths re-query a mutable cache.
// Thus every queued RPC is confined to the retained path/NAR/reference set.
static void copyFrozen(nix::Store & from, nix::Store & to,
    const std::map<nix::StorePath, nix::ValidPathInfo> & infos)
{
    std::map<nix::StorePath, size_t> remaining;
    std::map<nix::StorePath, nix::StorePathSet> referrers;
    nix::StorePathSet paths, ready;
    for (const auto & [path, info] : infos) {
        paths.insert(path);
        size_t count = 0;
        for (const auto & reference : info.references) if (reference != path) {
            require(infos.contains(reference));
            ++count;
            referrers[reference].insert(path);
        }
        remaining[path] = count;
        if (count == 0) ready.insert(path);
    }
    std::vector<nix::StorePath> ordered;
    while (!ready.empty()) {
        auto path = *ready.begin();
        ready.erase(ready.begin());
        ordered.push_back(path);
        for (const auto & referrer : referrers[path]) if (--remaining[referrer] == 0) ready.insert(referrer);
    }
    require(ordered.size() == infos.size());
    auto valid = to.queryValidPaths(paths, nix::NoSubstitute);
    for (const auto & path : ordered) if (!valid.contains(path)) {
        nix::ValidPathInfo info = infos.at(path);
        require(info.path == path);
        info.ultimate = false;
        auto source = nix::sinkToSource([&](nix::Sink & sink) {
            uint64_t left = info.narSize;
            nix::LambdaSink bounded([&](std::string_view bytes) {
                require(bytes.size() <= left);
                left -= bytes.size();
                sink(bytes);
            });
            from.narFromPath(path, bounded);
            require(left == 0);
        });
        to.addToStore(info, *source, nix::NoRepair, nix::CheckSigs);
    }
}

static nix::AutoCloseFD gcDescriptor(int inherited)
{
    for (const auto & parent : {"/nix", "/nix/var", "/nix/var/nix"}) {
        struct stat st;
        require(lstat(parent, &st) == 0 && S_ISDIR(st.st_mode) && st.st_uid == 0 && !(st.st_mode & 0022));
    }
    require(inherited >= 3 && (fcntl(inherited, F_GETFL) & O_ACCMODE) == O_RDONLY);
    nix::AutoCloseFD fd{fcntl(inherited, F_DUPFD_CLOEXEC, 3)};
    struct stat st;
    require(static_cast<bool>(fd) && fstat(fd.get(), &st) == 0 && S_ISREG(st.st_mode)
        && st.st_uid == 0 && st.st_nlink == 1 && !(st.st_mode & 0022));
    return fd;
}

struct HeldLock {
    nix::FdLock lock;
    HeldLock(int fd, nix::LockType type) : lock{fd, type, false, ""}
    {
        // Stock wait-mode omits acquired on immediate success. Use its working
        // nonblocking constructor, then the blocking primitive when necessary.
        if (!lock.acquired) lock.acquired = nix::lockFile(fd, type, true);
        require(lock.acquired);
    }
};

struct GcReadLock {
    nix::AutoCloseFD fd;
    HeldLock lock;
    explicit GcReadLock(int inherited)
        : fd{gcDescriptor(inherited)}, lock{fd.get(), nix::ltRead}
    {
        struct stat before, after;
        require(fstat(fd.get(), &before) == 0
            && lstat("/nix/var/nix/gc.lock", &after) == 0
            && before.st_dev == after.st_dev && before.st_ino == after.st_ino);
    }
};

// Native local filesystem reads, never publisher NARs or an "ultimate" shortcut.
static void verifyLocalBytes(const fs::path & path, const nix::ValidPathInfo & info)
{
    CheckedNar nar(info.narSize);
    nix::dumpPath(path, nar);
    auto [hash, size] = nar.hash.finish();
    require(nar.remaining == 0 && size == info.narSize && hash == info.narHash);
    if (info.ca) {
        nix::SourcePath sourcePath{nix::makeFSSourceAccessor(path)};
        const auto & ca = *info.ca;
        switch (ca.method.getFileIngestionMethod()) {
        case nix::FileIngestionMethod::Flat:
            require(fs::symlink_status(path).type() == fs::file_type::regular);
            [[fallthrough]];
        case nix::FileIngestionMethod::NixArchive: {
            nix::HashModuloSink sink{ca.hash.algo, std::string{info.path.hashPart()}};
            nix::dumpPath(sourcePath, sink, (nix::FileSerialisationMethod) ca.method.getFileIngestionMethod());
            require(sink.finish().hash == ca.hash);
            break;
        }
        case nix::FileIngestionMethod::Git:
            require(nix::git::dumpHash(ca.hash.algo, sourcePath).hash == ca.hash);
            break;
        }
    }
}

static void verifyShared(const Json & request, const fs::path & roots, const std::vector<std::string> & paths, int gcFd)
{
    // Only pure upstream path/fingerprint/CA operations use this dummy store.
    // No daemon, writable database, publisher access or readonly-SQLite/WAL view.
    auto store = nix::openStore(nix::StoreReference::parse("dummy://"));
    require(store->storeDir == "/nix/store");
    auto keys = trustedPublicKeys();
    const auto & expected = request.at("delivery").at("paths");
    require(expected.is_object() && expected.size() <= maxPaths);
    size_t references = 0;
    uint64_t total = 0;
    std::map<std::string, nix::ValidPathInfo> infos;
    for (const auto & [path, metadata] : expected.items()) {
        nix::ValidPathInfo info{store->parseStorePath(path), nix::UnkeyedValidPathInfo::fromJSON(&*store, metadata)};
        info.ultimate = false;
        require(info.storeDir == "/nix/store" && info.narHash.algo == nix::HashAlgorithm::SHA256
            && info.narSize > 0 && info.checkSignatures(*store, keys) > 0);
        references += info.references.size();
        require(references <= maxReferences && UINT64_MAX - total >= info.narSize);
        total += info.narSize;
        for (const auto & reference : info.references) require(expected.contains(store->printStorePath(reference)));
        infos.emplace(path, std::move(info));
    }
    const auto & prepared = request.at("delivery").at("prepared");
    const auto tree = prepared.at("source_path").get<std::string>();
    // Fence earlier collectors through local verification and durable roots.
    GcReadLock gc{gcFd};
    checkRoots(roots, paths);
    for (size_t i = 0; i < paths.size(); ++i) {
        require(expected.contains(paths[i]) || (request.at("tree").get<bool>() && paths[i] == tree));
        const auto root = roots / std::to_string(i);
        if (!rootExists(root, paths[i])) {
            require(request.at("publish_roots").get<bool>());
            nix::createSymlink(paths[i], root);
        }
    }
    directory(roots, true);
    directory(roots.parent_path(), true);
    directory(roots.parent_path().parent_path(), true);
    for (const auto & [path, info] : infos) verifyLocalBytes(path, info);
    if (request.at("tree").get<bool>()) {
        const auto hash = nix::Hash::parseAny(prepared.at("tree_digest").get<std::string>(), nix::HashAlgorithm::SHA256);
        if (expected.contains(tree)) {
            auto info = nix::UnkeyedValidPathInfo::fromJSON(&*store, expected.at(tree));
            require(info.narHash == hash && info.references.empty());
        } else {
            // Prepared trees are reference-free recursive content-addressed NARs.
            CheckedNar nar(512ULL * 1024 * 1024);
            nix::dumpPath(tree, nar);
            auto actual = nar.hash.finish();
            require(actual.hash == hash);
            nix::ValidPathInfo info{store->parseStorePath(tree), {*store, hash}};
            info.narSize = actual.numBytesDigested;
            info.ca = nix::ContentAddress::parse("fixed:r:sha256:" + hash.to_string(nix::HashFormat::Base16, false));
            require(info.checkSignatures(*store, keys) > 0);
        }
    }
    checkRoots(roots, paths);
    for (size_t i = 0; i < paths.size(); ++i) require(rootExists(roots / std::to_string(i), paths[i]));
    directory(roots, true);
    directory(roots.parent_path(), true);
    directory(roots.parent_path().parent_path(), true);
}

static nix::AutoCloseFD ownedDirectory(const fs::path & path, bool create)
{
    if (create) require(mkdir(path.c_str(), 0700) == 0 || errno == EEXIST);
    nix::AutoCloseFD fd{open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
    require(static_cast<bool>(fd));
    struct stat st;
    require(fstat(fd.get(), &st) == 0 && st.st_uid == geteuid() && !(st.st_mode & 0022));
    return fd;
}

// Unlike upstream's pathExists guard, lstat also rejects dangling foreign links.
static bool resultLink(const fs::path & path, const fs::path & target, bool replaceStoreLink)
{
    struct stat st;
    if (lstat(path.c_str(), &st) != 0) { require(errno == ENOENT); return false; }
    require(S_ISLNK(st.st_mode) && st.st_uid == geteuid());
    auto old = fs::read_symlink(path);
    if (old == target) return true;
    require(replaceStoreLink && old.parent_path() == "/nix/store");
    (void) nix::StorePath(old.filename().string());
    return false;
}

static void publishDevelopment(const Json & request, const fs::path & roots,
    const std::vector<std::string> & paths, int gcFd)
{
    const auto & development = request.at("development");
    const fs::path repository = development.at("repository").get<std::string>();
    require(fs::canonical(repository) == repository);
    auto repositoryFd = ownedDirectory(repository, false);
    struct stat repo;
    require(fstat(repositoryFd.get(), &repo) == 0
        && development.at("identity") == Json::array({repo.st_dev, repo.st_ino}));
    const auto result = repository / "result-dev";
    auto resultFd = ownedDirectory(result, true);
    nix::AutoCloseFD serial{openat(resultFd.get(), ".abird-owned-lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600)};
    struct stat st;
    require(static_cast<bool>(serial) && fstat(serial.get(), &st) == 0
        && S_ISREG(st.st_mode) && st.st_uid == geteuid() && st.st_nlink == 1 && (st.st_mode & 07777) == 0600);
    HeldLock serialLock{serial.get(), nix::ltWrite};
    for (size_t i = 0; i < paths.size(); ++i)
        require(rootExists(roots / std::to_string(i), paths[i]));

    const auto base = roots.parent_path().parent_path();
    const auto developmentBase = base / "development";
    auto developmentFd = ownedDirectory(developmentBase, true);
    const auto anchor = developmentBase / nix::hashString(nix::HashAlgorithm::SHA256, repository.string())
        .to_string(nix::HashFormat::Base16, false);
    auto anchorFd = ownedDirectory(anchor, true);
    const auto links = development.at("links").get<std::map<std::string, std::string>>();
    require(links.size() <= maxRoots);
    for (const auto & [name, target] : links) {
        require(!name.empty() && name.size() <= 255 && name != "." && name != ".."
            && name.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-") == std::string::npos
            && std::find(paths.begin(), paths.end(), target) != paths.end());
        resultLink(result / name, target, true);
        resultLink(anchor / name, result / name, false);
    }

    const bool shared = development.at("shared").get<bool>();
    std::unique_ptr<GcReadLock> gcLock;
    std::shared_ptr<nix::Store> to;
    nix::LocalFSStore * local = nullptr;
    nix::IndirectRootStore * indirect = nullptr;
    if (shared) {
        // Fixed worker opened this exact lock before dropping root. No ambient
        // caller lock access, daemon authority, writable DB or LocalStore.
        gcLock = std::make_unique<GcReadLock>(gcFd);
    } else {
        require(request.at("destination").at("uri") == "unix:///nix/var/nix/daemon-socket/socket");
        to = nix::openStore(nix::StoreReference::parse(request.at("destination").at("uri").get<std::string>()));
        local = dynamic_cast<nix::LocalFSStore *>(to.get());
        indirect = dynamic_cast<nix::IndirectRootStore *>(to.get());
        require(local && indirect && to->storeDir == "/nix/store" && local->getRealStoreDir() == "/nix/store"
            && to->getVersion() == std::optional<std::string>{"2.34.9"});
        for (const auto & [name, target] : links) to->addTempRoot(to->parseStorePath(target));
    }
    for (const auto & [name, target] : links) {
        const auto link = result / name;
        bool same = resultLink(link, target, true);
        if (shared) {
            if (!same) nix::replaceSymlink(target, link);
        } else if (!same) local->addPermRoot(to->parseStorePath(target), link);
        else indirect->addIndirectRoot(link);
        require(resultLink(link, target, false));
        // Upstream gc.cc follows this weak link exactly like gcroots/auto.
        // Keeping a caller-owned anchor lets us fsync its complete parent chain.
        if (!resultLink(anchor / name, link, false)) nix::createSymlink(link, anchor / name);
    }
    require(fsync(resultFd.get()) == 0 && fsync(repositoryFd.get()) == 0
        && fsync(anchorFd.get()) == 0 && fsync(developmentFd.get()) == 0);
    directory(base, true);
    // Directory replacement cannot turn an unrelated tree into a successful handoff.
    for (const auto & [path, fd] : std::vector<std::pair<fs::path, int>>{
        {repository, repositoryFd.get()}, {result, resultFd.get()},
        {anchor, anchorFd.get()}, {developmentBase, developmentFd.get()}}) {
        struct stat before, current;
        require(fstat(fd, &before) == 0 && lstat(path.c_str(), &current) == 0
            && S_ISDIR(current.st_mode) && current.st_dev == before.st_dev && current.st_ino == before.st_ino);
    }
}

// Each reply distinguishes RPC completion from client exit. A failed/interrupted
// copy is unconfirmed; neither closing a connection nor killing this helper is
// evidence that the daemon's importer settled.
EXPORTED int abird_owned_acquire(const char * input, int gcFd, Callback callback, void * user) noexcept
{
    if (used.exchange(true) || !input || !callback) return 1;
    std::string phase = "not_started";
    bool verified = false;
    bool developmentPublished = false;
    bool effectsConfined = false;
    std::string digest;
    try {
        size_t bytes = strnlen(input, 16 * 1024 * 1024 + 1);
        require(bytes <= 16 * 1024 * 1024);
        digest = nix::hashString(nix::HashAlgorithm::SHA256, std::string_view(input, bytes))
            .to_string(nix::HashFormat::Base16, false);
        auto request = Json::parse(input, input + bytes);
        require(request.at("version") == 2
            && fs::canonical(request.at("program").get<std::string>())
                == fs::canonical(ABIRD_NIX_PROGRAM));
        const auto source = request.at("source").get<std::string>();
        require((source.starts_with("https://") || source.starts_with("http://")
            || source.starts_with("s3://")) && source.find_first_of("@?# \t\r\n") == std::string::npos);
        const bool import = request.at("import").get<bool>();
        const bool reconcile = request.value("reconcile_only", false);
        const bool discard = request.value("discard", false);
        require((!reconcile || !import) && (!discard || reconcile));
        const auto paths = request.at("paths").get<std::vector<std::string>>();
        require(paths.size() <= maxRoots);
        const fs::path roots = request.at("roots").get<std::string>();
        checkRoots(roots, paths);
        nix::initNix(); // Local public-key configuration; no plugins or trust override.
        if (request.contains("development") && !request.at("development").is_null()) {
            require(!import && !reconcile);
            publishDevelopment(request, roots, paths, gcFd);
            developmentPublished = true;
        } else if (request.value("shared_verify", false)) {
            require(!import && !reconcile && !discard);
            verifyShared(request, roots, paths, gcFd);
            verified = true;
        } else {
        require(request.at("destination").at("uri") == "unix:///nix/var/nix/daemon-socket/socket");
        auto to = nix::openStore(nix::StoreReference::parse(
            request.at("destination").at("uri").get<std::string>()));
        // After ACK the builder may retire its roots/cache content. A recheck
        // needs only local bytes and retained cryptographic proof, not source liveness.
        auto from = import ? nix::openStore(nix::StoreReference::parse(source)) : to;
        require(from->storeDir == "/nix/store");
        auto * local = dynamic_cast<nix::LocalFSStore *>(&*to);
        require(local && to->storeDir == "/nix/store" && local->getRealStoreDir() == "/nix/store"
            && to->getVersion() == std::optional<std::string>{"2.34.9"});
        if (discard) {
            // Caller has durably revoked consumption and fenced every old
            // caller-side root producer. Profile 2 authenticated/froze the exact
            // declarations BEFORE any addToStore RPC and fixed NoRepair/CheckSigs
            // against this upstream daemon version. Any remaining daemon work
            // can only commit those immutable objects (or fail), never create
            // caller roots/ACK/activation. Missing objects need not be copied:
            // late objects and daemon temporary roots remain Nix-managed state.
            // This is discard confinement, NOT successful consumption, producer
            // termination, or a claim that all daemon temporary roots vanished.
            effectsConfined = true;
        } else {
        auto keys = trustedPublicKeys();
        auto expected = request.at("delivery").at("paths");
        require(expected.is_object() && expected.size() <= maxPaths);
        const auto & prepared = request.at("delivery").at("prepared");
        if (request.at("tree").get<bool>()) {
            auto tree = prepared.at("source_path").get<std::string>();
            auto info = from->queryPathInfo(from->parseStorePath(tree));
            require(info->narHash.to_string(nix::HashFormat::Base16, false)
                == prepared.at("tree_digest").get<std::string>());
            require(info->references.empty() && info->narSize <= 512ULL * 1024 * 1024);
            auto treeInfo = info->toJSON(&*from, true, nix::PathInfoJsonFormat::V1);
            if (expected.contains(tree)) matches(*from, *info, expected.at(tree));
            else expected[tree] = treeInfo;
        }
        require(expected.size() <= maxPaths + 1);
        nix::StorePathSet closure;
        size_t references = 0;
        uint64_t total = 0;
        std::map<nix::StorePath, nix::ValidPathInfo> signedInfo;
        // Exact bounded closure, not an unbounded recursive source query. Verify
        // source signatures even when every destination path already exists.
        for (const auto & [path, metadata] : expected.items()) {
            auto parsed = from->parseStorePath(path);
            auto info = from->queryPathInfo(parsed);
            require(info->path == parsed); // Reject queryPathInfo's hash-only `-x` alias.
            matches(*from, *info, metadata);
            if (import) require(info->checkSignatures(*from, keys) > 0);
            references += info->references.size();
            require(references <= maxReferences && UINT64_MAX - total >= info->narSize);
            total += info->narSize;
            for (const auto & reference : info->references)
                require(expected.contains(from->printStorePath(reference)));
            closure.insert(parsed);
            signedInfo.emplace(parsed, *info);
        }
        for (const auto & path : paths) require(expected.contains(path));
        // Protect every member before import: a not-yet-valid output cannot
        // transitively protect dependencies imported earlier in the copy.
        for (const auto & path : closure) to->addTempRoot(path);
        if (import) {
            phase = "unconfirmed";
            copyFrozen(*from, *to, signedInfo);
            phase = "completed"; // Synchronous import RPCs returned, not process-exit inference.
        }
        // Rehash the *local* NAR and authenticate its fingerprint with locally
        // trusted keys. Original retained signatures also prove already-valid
        // local objects without stored signatures. Ultimate is never proof.
        for (const auto & [path, sourceInfo] : signedInfo) {
            auto info = to->queryPathInfo(path);
            require(info->path == path);
            matches(*to, *info, expected.at(to->printStorePath(path)));
            nix::ValidPathInfo authenticated = *info;
            authenticated.ultimate = false;
            const auto & metadata = expected.at(to->printStorePath(path));
            for (const auto & signature : metadata.value("signatures", Json::array()))
                authenticated.sigs.insert(nix::Signature::parse(signature.get<std::string>()));
            // The CA field was checked against the retained/source metadata;
            // checkSignatures additionally proves that it determines this path.
            require(authenticated.checkSignatures(*to, keys) > 0);
            require(sourceInfo.narHash == info->narHash);
            verifyLocalBytes(local->toRealPath(path), *info);
        }
        checkRoots(roots, paths);
        for (size_t i = 0; i < paths.size(); ++i) {
            auto root = roots / std::to_string(i);
            if (!rootExists(root, paths[i])) {
                require(import); // ACK retries are verification-only, never root repair.
                // This is already inside the provisioned direct-root directory.
                // Temporary roots close the GC window; atomic symlink creation
                // avoids upstream addPermRoot's unbounded .tmp-* crash residue.
                nix::createSymlink(paths[i], root);
            }
            require(rootExists(root, paths[i]));
        }
        directory(roots, true);
        directory(roots.parent_path(), true);
        directory(roots.parent_path().parent_path(), true);
        // Store/temporary-root lifetime extends past permanent-root durability.
        // Together with the caller helper fence this discharges older NoRepair
        // effects; it does not assert daemon-process termination.
        effectsConfined = true;
        verified = true;
        }
        }
    } catch (...) {
        // Native failures are private; no paths, config, credentials or raw Nix diagnostics in reply.
    }
    try {
        auto reply = Json{{"version", 2}, {"request_digest", digest},
            {"import_state", phase}, {"verified", verified}, {"development_published", developmentPublished},
            {"effects_confined", effectsConfined}}.dump();
        return callback(reply.data(), reply.size(), user);
    } catch (...) { return 1; }
}
