//! Representation regressions; no native source-equivalence claims.
use super::*;
use crate::build_executor::preparation::git_context::hex;

#[test]
fn declared_source_budget_bounds_encoding_without_raising_the_protocol_ceiling() {
    let limits = crate::build_executor::private_tree::Limits {
        bytes: 64 * 1024 * 1024,
        entries: 32768,
        depth: 64,
    };
    let bound = material_limit(limits).unwrap();
    // Metadata-only measurement of this repository's real common Git closure.
    assert!(bound > 2 * 42_132_488);
    assert!(bound < MAX_MATERIAL_BYTES);
    assert!(
        material_limit(crate::build_executor::private_tree::Limits {
            bytes: 8 * 1024 * 1024,
            ..limits
        })
        .unwrap()
            < bound
    );
    assert!(
        material_limit(crate::build_executor::private_tree::Limits { bytes: 0, ..limits }).is_err()
    );
}

#[test]
fn streaming_json_hash_is_the_same_domain_separated_encoding() {
    let value = serde_json::json!({ "private": "a\\b\nquoted\"", "roots": [1, 2] });
    let json = serde_json::to_vec(&value).unwrap();
    encoding::require_size(&value, json.len()).unwrap();
    assert!(encoding::require_size(&value, json.len() - 1).is_err());
    let mut expected = b"capsule-test\n".to_vec();
    expected.extend_from_slice(&json);
    assert_eq!(
        encoding::json_digest(b"capsule-test\n", &value, expected.len()).unwrap(),
        crate::sha256::digest_bytes(&expected)
    );
    assert!(encoding::json_digest(b"capsule-test\n", &value, expected.len() - 1).is_err());
}

#[test]
fn streaming_hex_hash_has_exact_bounds_and_rejects_noncanonical_encodings() {
    let bytes = vec![0xac; 8193]; // crosses the fixed decoding chunk boundary
    let text = hex(&bytes);
    assert_eq!(
        encoding::hex_digest(&text, bytes.len()).unwrap(),
        crate::sha256::digest_bytes(&bytes)
    );
    assert!(encoding::hex_digest(&text, bytes.len() - 1).is_err());
    for invalid in ["a", "AA", "0g", "é"] {
        assert!(encoding::hex_digest(invalid, 8193).is_err());
    }
}
