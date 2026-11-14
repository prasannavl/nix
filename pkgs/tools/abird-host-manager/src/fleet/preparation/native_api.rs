//! Manager-private bridge to unpatched upstream Nix C++ libraries. All native
//! state remains in one retained-root worker; no C++ objects cross the boundary.
//! Same-root association alone does not qualify original profiles/accessors.

use std::ffi::{CStr, CString, c_char, c_int, c_uint, c_void};
use std::marker::PhantomData;
use std::os::unix::{ffi::OsStrExt, fs::MetadataExt};
use std::path::{Path, PathBuf};
use std::ptr::{self, NonNull};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};

use abird_host_agent::build_executor::process::Limits;
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use crate::fleet::build::query::{FlakeQuery, Selection};

const MAX_RESULT: usize = 16 * 1024 * 1024;
pub(crate) const QUERY_LIMITS: Limits = Limits {
    stdin: 64 * 1024,
    stdout: MAX_RESULT,
    stderr: 128 * 1024,
};
static USED: AtomicBool = AtomicBool::new(false);
type Pointer = *mut c_void;
type StringCallback = unsafe extern "C" fn(*const c_char, usize, Pointer) -> c_int;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub version: u32,
    pub program: PathBuf,
    pub reference: String,
    pub system: String,
    pub query: FlakeQuery,
}

#[derive(Deserialize)]
#[serde(untagged)]
pub(crate) enum WorkerRequest {
    Flake(Request),
    Inventory(InventoryRequest),
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
enum InventoryKind {
    Inventory,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct InventoryRequest {
    kind: InventoryKind,
    version: u32,
    program: PathBuf,
    system: String,
    expression: String,
    allowed_uris: std::collections::BTreeSet<String>,
}

impl InventoryRequest {
    pub(crate) fn new(
        program: &Path,
        system: &str,
        input: &super::snapshot::InventoryExpression,
    ) -> Result<Self> {
        let result = Self {
            kind: InventoryKind::Inventory,
            version: 1,
            program: program.to_owned(),
            system: system.to_owned(),
            expression: input.expression.clone(),
            allowed_uris: input.allowed_uris.clone(),
        };
        result.validate()?;
        Ok(result)
    }

    fn validate(&self) -> Result<()> {
        ensure!(
            self.version == 1
                && self.program.starts_with("/nix/store")
                && self.program.ends_with("bin/nix")
                && self.program.as_os_str().len() <= 4096
                && !self.expression.is_empty()
                && !self.expression.contains('\0')
                && (1..=2).contains(&self.allowed_uris.len())
                && self
                    .allowed_uris
                    .iter()
                    .all(|uri| uri.starts_with("path:/nix/store/")
                        && uri.contains("?narHash=sha256-")
                        && !uri.chars().any(char::is_whitespace)
                        && !uri.chars().any(char::is_control))
                && serde_json::to_vec(self)?.len() <= QUERY_LIMITS.stdin,
            "invalid native inventory request"
        );
        configuration(&self.system)?;
        Ok(())
    }

    fn evaluate(&self, library: &Path) -> Result<Vec<u8>> {
        self.validate()?;
        let input = CString::new(serde_json::to_vec(self)?)?;
        let api = Api::bound(library, &self.program, &self.system)?;
        type Evaluate = unsafe extern "C" fn(*const c_char, StringCallback, Pointer) -> c_int;
        let evaluate = unsafe {
            std::mem::transmute::<Pointer, Evaluate>(
                api._library.symbol(c"abird_owned_nix_inventory")?,
            )
        };
        abird_host_agent::build_executor::process::restrict_worker_exec()?;
        let mut bytes = CapturedString::new(MAX_RESULT);
        let status = unsafe {
            evaluate(
                input.as_ptr(),
                capture_string,
                ptr::from_mut(&mut bytes).cast(),
            )
        };
        ensure!(status == 0, "native inventory evaluation failed");
        bytes.finish()
    }
}

pub(crate) fn evaluate_worker(request: &WorkerRequest, library: &Path) -> Result<Vec<u8>> {
    match request {
        WorkerRequest::Flake(request) => evaluate(request, library),
        WorkerRequest::Inventory(request) => request.evaluate(library),
    }
}

/// `source_info` is produced from upstream fetcher/evaluator objects after the
/// adapter's accessor-identity and lock checks, not from evaluated flake values.
/// `inputs` names locked external flake inputs actually mounted so far.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Observation {
    pub version: u32,
    pub source_info: serde_json::Map<String, serde_json::Value>,
    pub inputs: Vec<String>,
    pub selection: Selection,
}

impl Request {
    fn expression(&self) -> Result<CString> {
        ensure!(self.version == 2, "unsupported native API query");
        ensure!(
            !self.reference.is_empty()
                && self.reference.len() <= 32 * 1024
                && !self.reference.contains('#')
                && !self.reference.chars().any(char::is_control),
            "invalid native API reference"
        );
        ensure!(
            self.program.starts_with("/nix/store")
                && self.program.ends_with("bin/nix")
                && self.program.as_os_str().len() <= 4096,
            "invalid native API program"
        );
        CString::new(self.query.source_expression(&self.system)?)
            .context("invalid fixed native expression")
    }
}

/// One immutable root and evaluator for all queries in the original worker.
/// Neither movement across threads nor reopening after any failure is allowed.
/// The outer admitted runner owns the deadline and descendant settlement.
pub(crate) struct Session {
    handle: NonNull<c_void>,
    api: Api,
    system: String,
    poisoned: bool,
    _thread: PhantomData<Rc<()>>,
}

impl Session {
    pub(crate) fn open(request: &Request, library: &Path, cwd: &Path) -> Result<Self> {
        request.expression()?;
        ensure!(
            cwd.is_absolute() && cwd.as_os_str().len() <= 4096,
            "invalid native API base directory"
        );
        let reference = CString::new(request.reference.as_bytes())?;
        let base = CString::new(cwd.as_os_str().as_bytes())?;
        let api = Api::bound(library, &request.program, &request.system)?;
        // Inventory CLI calls and any distinct-root worker precede this retained
        // root. No later caller helper may inherit native store credentials.
        abird_host_agent::build_executor::process::restrict_worker_exec()?;
        let handle =
            NonNull::new(unsafe { (api.abird_owned_nix_open)(reference.as_ptr(), base.as_ptr()) })
                .context("native API root unavailable")?;
        Ok(Self {
            handle,
            api,
            system: request.system.clone(),
            poisoned: false,
            _thread: PhantomData,
        })
    }

    pub(crate) fn query(&mut self, query: &FlakeQuery) -> Result<Vec<u8>> {
        ensure!(!self.poisoned, "native API session unresolved");
        self.poisoned = true;
        let expression = CString::new(query.source_expression(&self.system)?)?;
        let mut bytes = CapturedString::new(MAX_RESULT);
        let status = unsafe {
            (self.api.abird_owned_nix_query)(
                self.handle.as_ptr(),
                expression.as_ptr(),
                capture_string,
                ptr::from_mut(&mut bytes).cast(),
            )
        };
        ensure!(status == 0, "native API operation failed");
        let bytes = bytes.finish()?;
        self.poisoned = false;
        Ok(bytes)
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        unsafe { (self.api.abird_owned_nix_close)(self.handle.as_ptr()) };
    }
}

/// One-shot entry uses the same retained-root implementation, not a fallback.
pub fn evaluate(request: &Request, library: &Path) -> Result<Vec<u8>> {
    Session::open(request, library, &std::env::current_dir()?)?.query(&request.query)
}

pub fn configuration(system: &str) -> Result<String> {
    abird_host_agent::build_executor::preparation::worker::evaluation_configuration(system)
}

struct CapturedString {
    bytes: Vec<u8>,
    limit: usize,
    called: bool,
    invalid: bool,
}

impl CapturedString {
    fn new(limit: usize) -> Self {
        Self {
            bytes: Vec::new(),
            limit,
            called: false,
            invalid: false,
        }
    }
    fn finish(self) -> Result<Vec<u8>> {
        ensure!(
            self.called && !self.invalid,
            "native API string is incomplete or exceeds bound"
        );
        Ok(self.bytes)
    }
}

unsafe extern "C" fn capture_string(start: *const c_char, count: usize, user: Pointer) -> c_int {
    // Called synchronously with our live stack object. Never unwind through C.
    let target = unsafe { &mut *user.cast::<CapturedString>() };
    if target.called || count > target.limit || (count != 0 && start.is_null()) {
        target.invalid = true;
        return 1;
    }
    target.called = true;
    if target.bytes.try_reserve_exact(count).is_err() {
        target.invalid = true;
        return 1;
    }
    if count != 0 {
        target
            .bytes
            .extend_from_slice(unsafe { std::slice::from_raw_parts(start.cast(), count) });
    }
    0
}

// Our narrow C ABI, never upstream C++ layouts or ambient symbol fallback.
macro_rules! api {
    ($($name:ident: fn($($argument:ty),*) -> $result:ty),+ $(,)?) => {
        struct Api { _library: Library,
            $($name: unsafe extern "C" fn($($argument),*) -> $result,)+ }
        impl Api {
            fn load(path: &Path) -> Result<Self> {
                let library = Library::open(path)?;
                Ok(Self {
                    $($name: unsafe {
                        std::mem::transmute::<Pointer,
                            unsafe extern "C" fn($($argument),*) -> $result>(
                            library.symbol(CStr::from_bytes_with_nul(
                                concat!(stringify!($name), "\0").as_bytes())?)?
                        )
                    },)+
                    _library: library,
                })
            }
        }
    };
}

api! {
    abird_owned_nix_abi: fn() -> c_uint,
    abird_owned_nix_program: fn() -> *const c_char,
    abird_owned_nix_open: fn(*const c_char, *const c_char) -> Pointer,
    abird_owned_nix_close: fn(Pointer) -> (),
    abird_owned_nix_query: fn(Pointer, *const c_char, StringCallback, Pointer) -> c_int,
}

impl Api {
    fn bound(library: &Path, expected: &Path, system: &str) -> Result<Self> {
        ensure!(
            std::env::var("NIX_CONFIG").ok().as_deref() == Some(configuration(system)?.as_str()),
            "native API evaluation flags differ"
        );
        ensure!(
            library == std::env::current_exe()?.with_file_name("libabird-owned-nix.so"),
            "native API library is outside the manager package"
        );
        ensure!(
            !USED.swap(true, Ordering::AcqRel),
            "native API process already consumed"
        );
        let api = Self::load(library)?;
        ensure!(
            unsafe { (api.abird_owned_nix_abi)() } == 3,
            "unsupported native adapter ABI"
        );
        let program = unsafe { (api.abird_owned_nix_program)() };
        ensure!(
            !program.is_null()
                && unsafe { libc::strnlen(program, 4097) } <= 4096
                && unsafe { CStr::from_ptr(program) }.to_bytes() == expected.as_os_str().as_bytes(),
            "native adapter Nix package differs"
        );
        Ok(api)
    }
}

struct Library(NonNull<c_void>);
impl Library {
    fn open(path: &Path) -> Result<Self> {
        ensure!(
            path.is_absolute() && path.starts_with("/nix/store"),
            "native API library is not immutable"
        );
        let canonical = std::fs::canonicalize(path)?;
        let metadata = std::fs::metadata(&canonical)?;
        ensure!(
            canonical.starts_with("/nix/store")
                && metadata.is_file()
                && metadata.uid() == 0
                && metadata.mode() & 0o022 == 0,
            "native API library authority differs"
        );
        let name = CString::new(canonical.as_os_str().as_bytes())?;
        // Native runtime teardown may outlive our handles. Keep code mapped for
        // this one bounded subprocess; no dlclose/reload or ambient library path.
        let handle = unsafe {
            libc::dlopen(
                name.as_ptr(),
                libc::RTLD_NOW | libc::RTLD_LOCAL | libc::RTLD_NODELETE,
            )
        };
        Ok(Self(
            NonNull::new(handle).context("native API library unavailable")?,
        ))
    }
    fn symbol(&self, name: &CStr) -> Result<Pointer> {
        let value = unsafe { libc::dlsym(self.0.as_ptr(), name.as_ptr()) };
        ensure!(!value.is_null(), "required native API symbol unavailable");
        Ok(value)
    }
}
impl Drop for Library {
    fn drop(&mut self) {
        unsafe { libc::dlclose(self.0.as_ptr()) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replacement_requests_reject_old_protocol_and_invalid_inputs_before_loading() {
        let mut request = Request {
            version: 2,
            program: "/nix/store/00000000000000000000000000000000-nix/bin/nix".into(),
            reference: "git+file:///caller/repo".into(),
            system: "x86_64-linux".into(),
            query: FlakeQuery::value("value"),
        };
        assert!(request.expression().is_ok());
        let encoded = serde_json::to_vec(&request).unwrap();
        assert!(!encoded.is_empty() && encoded.len() <= QUERY_LIMITS.stdin);
        request.version = 1;
        assert!(request.expression().is_err());
        request.version = 2;
        request.reference.push_str("#value");
        assert!(request.expression().is_err());
        request.reference = "git+file:///caller/repo".into();
        request.program = "/usr/bin/nix".into();
        assert!(request.expression().is_err());
    }

    #[test]
    fn inventory_requests_are_distinct_bounded_and_exact_uri_restricted() {
        let input = super::super::snapshot::InventoryExpression {
            expression: "{ value = 1; }".into(),
            allowed_uris: std::collections::BTreeSet::from([format!(
                "path:/nix/store/{}-source?narHash=sha256-fixture%3D",
                "a".repeat(32)
            )]),
        };
        let program = Path::new("/nix/store/00000000000000000000000000000000-nix/bin/nix");
        let mut request = InventoryRequest::new(program, "x86_64-linux", &input).unwrap();
        let encoded = serde_json::to_vec(&request).unwrap();
        assert!(matches!(
            serde_json::from_slice::<WorkerRequest>(&encoded).unwrap(),
            WorkerRequest::Inventory(_)
        ));
        assert!(serde_json::from_slice::<Request>(&encoded).is_err());
        let mut unknown = serde_json::to_value(&request).unwrap();
        unknown["kind"] = serde_json::json!("unrestricted");
        assert!(serde_json::from_value::<WorkerRequest>(unknown).is_err());
        request
            .allowed_uris
            .insert("https://unbound.example".into());
        assert!(request.validate().is_err());
        request.allowed_uris = input.allowed_uris;
        request.expression = "x".repeat(QUERY_LIMITS.stdin);
        assert!(request.validate().is_err());
        request.expression = "{}".into();
        request.version = 0;
        assert!(request.validate().is_err());
    }

    #[test]
    fn source_metadata_must_be_an_object_not_an_outpath_coercion() {
        use serde_json::{from_value, json};
        let path = "/nix/store/00000000000000000000000000000000-source";
        let mut value = json!({
            "version": 2,
            "source_info": {"outPath": path, "narHash": "metadata"},
            "inputs": ["nixpkgs"],
            "selection": {"version": 1, "system": "x86_64-linux", "present": true,
                "attribute": "value", "result": null}
        });
        let observed = from_value::<Observation>(value.clone()).unwrap();
        assert_eq!(observed.source_info["outPath"], path);
        assert_eq!(observed.source_info["narHash"], "metadata");
        for invalid in [json!(path), json!(null), json!([])] {
            value["source_info"] = invalid;
            assert!(from_value::<Observation>(value.clone()).is_err());
        }
    }

    #[test]
    fn callback_requires_one_complete_bounded_string_without_unwinding() {
        for (bytes, limit, valid) in [
            (b"hello".as_slice(), 5, true),
            (b"hello".as_slice(), 4, false),
            (b"".as_slice(), 0, true),
        ] {
            let mut value = CapturedString::new(limit);
            unsafe {
                capture_string(
                    bytes.as_ptr().cast(),
                    bytes.len(),
                    ptr::from_mut(&mut value).cast(),
                )
            };
            assert_eq!(value.finish().is_ok(), valid);
        }
        let mut repeated = CapturedString::new(4);
        unsafe {
            capture_string(c"a".as_ptr(), 1, ptr::from_mut(&mut repeated).cast());
            capture_string(c"b".as_ptr(), 1, ptr::from_mut(&mut repeated).cast());
        }
        assert!(repeated.finish().is_err());
        assert!(CapturedString::new(4).finish().is_err());
        let mut missing = CapturedString::new(4);
        unsafe { capture_string(ptr::null(), 1, ptr::from_mut(&mut missing).cast()) };
        assert!(missing.finish().is_err());
    }
}
