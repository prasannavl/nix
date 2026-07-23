# External Patch Upstreamability Audit — 2026-07

## Scope

This audit covers repo-owned modifications to third-party software:

- 24 explicit patch files under `pkgs/ext`: 3 Bulwarkmail, 14 Stalwart, and 7
  Z-Push.
- The scripted MiroFish source rewrite in `pkgs/ext/mirofish/helper.sh`.
- The Kanidm UI overlay in `pkgs/ext/kanidm-server`.
- Packaging-only rewrites in `pkgs/ext/bulwarkmail`, `lib/ext/vscode`, and
  `lib/ext/zed.nix`.

It does not classify ordinary NixOS configuration, version pins, generated
configuration, or build procedures that leave upstream source unchanged.

The upstream snapshot was refreshed on 2026-07-14:

- Bulwarkmail local pin: `1.7.5`; latest release: `1.7.7`; upstream `main`:
  `01e5cd69cf19b9170c1aa256635feb7686ca6472`.
- Stalwart local pin: `0.16.11`; latest release: `0.16.13`; upstream `main`:
  `45602a35ba1cbec189ae4468019063417f371b4f`.
- Z-Push local and latest release: `2.7.6`; upstream `develop`:
  `659ecf897d1b1f37c90098dd4ae73237a1cf37ac`.
- MiroFish local pin and upstream `main`:
  `96096ea0ff42b1a30cbc41a1560b8c91090f9968`.
- Kanidm upstream `master`: `1dba0b9f359c34de6cffb5af57d3f4011496f354`.

## Classifications

- **Submit**: generic bug fix with a concrete reproducer; rebase and test before
  submission.
- **Prepare**: useful upstream change, but split, redesign, security review, or
  stronger tests are required first.
- **Track**: upstream already implements the behavior or an existing upstream
  pull request covers it; do not submit a duplicate.
- **Local**: distribution, deployment, or product policy; not suitable for the
  application upstream as written.

These labels describe technical fit, not permission to publish. The follow-up
publication pass is recorded in `external-patch-pr-drafts-2026-07.md`: two
Z-Push draft PRs are open, and five Stalwart fork branches await the
repository's support/vouch/FLA gate.

## Recommended Queue

1. Clean up the Bulwarkmail stack before creating new upstream work: upgrade to
   `1.7.7`, remove the now-upstream calendar construction changes, and retain at
   most the small organizer-detection delta until upstream PR
   [#527](https://github.com/bulwarkmail/webmail/pull/527) lands.
2. Take the smallest Stalwart bug fixes through the support/vouch process one at
   a time: calendar `MAILTO` normalization, floating-timezone snapshot handling,
   IMAP STORE pipeline ordering, selected-mailbox IDLE response shape, and DMARC
   without MAIL FROM SPF.
3. Submit the two narrow Z-Push interoperability fixes first: CardDAV
   `getcontenttype` in sync reports and Windows-timezone-name mapping. Expect a
   slow review cycle: the last `develop` code change was the 2.7.6 release in
   July 2025, although contributors continued opening PRs in 2026.
4. For MiroFish, avoid duplicating existing PRs. The best new candidates are
   graph-build timeout/failure propagation and optional reasoning effort, but
   upstream `main` has not moved since May 2026 and has a large open-PR queue.
5. Keep the Kanidm DOM overlay local. Propose native self-service application
   password UI as an upstream product feature separately; the Abird JavaScript
   injection and app-grid ordering are not a suitable upstream implementation.

## Bulwarkmail

| Patch                                     | Class | Assessment                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ----------------------------------------- | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `calendar-organizer-attendee-shape.patch` | Track | Upstream 1.7.6/1.7.7 independently added `organizerCalendarAddress`, switched organizer construction to owner-only to avoid duplicate organizer/attendee rendering, and updated JSCalendar scheduling fields. The remaining event-level organizer fallback overlaps open PR [#527](https://github.com/bulwarkmail/webmail/pull/527). Upgrade and shrink/drop the local patch; do not submit it wholesale.                                                     |
| `local-geist-fonts.patch`                 | Local | Replaces `next/font/google` with Nix-provided local fonts for sandboxed, reproducible builds. This belongs in Nix packaging unless Bulwark chooses to bundle fonts as a product decision.                                                                                                                                                                                                                                                                     |
| `server-logout-route.patch`               | Local | No repo consumer calls `/api/auth/logout`. Current Bulwark already revokes OAuth refresh tokens and supports RP-initiated logout through `/api/auth/token`. The local route duplicates part of that behavior, mutates auth state through `GET`, hardcodes `/en/login`, has no tests, and assumes a bounded account-slot scan. Drop unless a real noninteractive logout consumer is identified; redesign as a tested POST-only upstream feature if one exists. |

The `next build --turbopack` to `next build --webpack` substitution is a build
workaround, not an application patch. Revisit it in the Nix package after the
version bump.

## Stalwart

Stalwart's current contribution policy accepts bug fixes and very small scoped
changes, requires contributors to be vouched through
[support.stalw.art](https://support.stalw.art), requires an FLA, and says every
submitted line must be understood and human-reviewed. Large configuration
features should start as feature discussions, not PRs. Keep each candidate in
its own support topic and branch.

| Patch                                              | Class   | Assessment                                                                                                                                                                                                                                                                                                                                                                            |
| -------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bind-auth-dn-template.patch`                      | Prepare | Generic LDAP interoperability for directories such as Kanidm where the lookup result DN differs from the application-password bind DN. Upstream already supports lookup bind and template bind separately; this hybrid is still distinct. It is a registry-sized feature, so start with a minimal reproducer and support feature discussion. Add escaping and invalid-template tests. |
| `calendar-default-display-name-policy.patch`       | Local   | Makes account-name suffixing optional while retaining the upstream default. Useful, but it is presentation policy rather than a bug and is unlikely to fit the present contribution rules. Keep local unless maintainers request the option.                                                                                                                                          |
| `calendar-floating-timezone-summary.patch`         | Submit  | Seven-line correctness fix preventing a floating timezone's sentinel ID from becoming the serialized snapshot timezone code. Add a focused scheduling snapshot test showing the bad value and UTC fallback.                                                                                                                                                                           |
| `calendar-imip-method-fallback-policy.patch`       | Prepare | Split into two changes. Body `METHOD:` fallback is a bounded compatibility feature with an RFC-strict default. `iMipAllowExternalSender` changes an authentication boundary and needs a threat model, explicit trusted-delivery assumptions, and tests proving spoofed replies cannot mutate calendar state.                                                                          |
| `calendar-mailto-normalization.patch`              | Submit  | Small, generic bug fix: strips `MAILTO:` case-insensitively before constructing SMTP recipients. The real Brevo rejection is a strong reproducer. Rebase on current main and add upper/lower/mixed-case tests.                                                                                                                                                                        |
| `calendar-organizer-attendee-export-policy.patch`  | Prepare | Generic client-interoperability option, but the patch touches many call paths and RFC permits organizer-as-attendee. Reduce parameter plumbing, add end-to-end iTIP fixtures, and first establish which clients require suppression. Do not propose it as a new default.                                                                                                              |
| `calendar-organizer-snapshot-dedupe-policy.patch`  | Prepare | Internal dedupe can be a correctness fix even when wire serialization preserves organizer-as-attendee. Isolate the snapshot function, demonstrate double-processing, and submit separately from export policy.                                                                                                                                                                        |
| `calendar-reply-sender-detection-policy.patch`     | Prepare | Valuable compatibility behavior, but security-sensitive. The current guard requiring exactly one changed attendee and SMTP/SENT-BY agreement is the right direction. Add adversarial multi-attendee, mismatched-sender, delegation, and recurrence tests before discussion.                                                                                                           |
| `calendar-organizer-cn-from-identity-policy.patch` | Prepare | Generic quality improvement, not protocol correctness. The current patch is large for presentation behavior. Reduce it to a focused identity lookup/helper with tests or keep it local under the current contribution policy.                                                                                                                                                         |
| `dmarc-without-mail-from-spf.patch`                | Submit  | DMARC must still evaluate DKIM alignment when MAIL FROM SPF is unavailable. Upstream's July DMARCbis work still gates DMARC on `spf_mail_from`, so the bug remains, but the patch must be rebased on `mail-auth` 0.11/DMARCbis and gain null-sender, SPF-none/DKIM-pass, and SPF-none/DKIM-fail tests.                                                                                |
| `imap-idle-selected-mailbox-updates.patch`         | Submit  | Strong protocol/client case with extensive tests. The maintainer agreed the selected mailbox should not receive unsolicited `STATUS`; the local patch follows that corrected direction while preserving `EXISTS`, `EXPUNGE`, `FETCH`, and non-selected status updates. Refresh the support topic against current main before submission.                                              |
| `imap-quota-empty-root-compat.patch`               | Prepare | Avoids Thunderbird's parser failure on `QUOTA "#id" ()` and avoids advertising a nonexistent quota root. RFC 9208 allows an empty list, so frame this as client compatibility, not standards correction. Regenerate the zero-context/overlapping patch as a normal current-main diff and add operation-level tests, not only serializer helper tests.                                 |
| `imap-starttls-auth.patch`                         | Prepare | Useful secure-by-policy option: suppress and reject cleartext SASL until TLS while preserving upstream behavior by default. It is a cross-registry feature, not a tiny bug fix. Discuss first; add pre-TLS greeting/CAPABILITY, AUTH rejection, post-STARTTLS capability, implicit-TLS, OAuth, and config migration tests.                                                            |
| `imap-store-pipeline-sync.patch`                   | Submit  | Clear RFC command-ordering bug: fire-and-forget STORE can race a pipelined EXPUNGE. Regenerate the patch because its missing final newline makes `git apply` report it as corrupt. Add one integration test that pipelines STORE then EXPUNGE and asserts the message is removed before proposing it upstream.                                                                        |

Patch-stack hygiene matters before any Stalwart submission:

- Later calendar patches were generated against earlier local patches, so they
  do not apply independently to clean upstream `main`.
- `imap-quota-empty-root-compat.patch` uses zero-context overlapping hunks that
  GNU `patch` accepts but `git apply` does not apply cleanly.
- `imap-store-pipeline-sync.patch` is missing its final newline and is rejected
  as corrupt by `git apply`.
- Recreate every upstream candidate as one clean commit on current `main`, with
  no local numeric registry-ID collisions and no unrelated Abird policy.

## Z-Push

Z-Push accepts GitHub PRs and requires contributors to state that the code is
released under AGPLv3. The project still accepts occasional changes, but review
throughput is low: multiple 2025/2026 PRs remain open and `develop` has had no
code changes since the 2.7.6 release.

| Patch                                           | Class   | Assessment                                                                                                                                                                                                                                                                                                                                                            |
| ----------------------------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `carddav-extensionless-sync-report.patch`       | Submit  | One-line generic fix: request `getcontenttype` so extensionless CardDAV hrefs can be identified as vCards. Add a Stalwart-style sync response fixture. This complements, rather than duplicates, merged Radicale PR [#100](https://github.com/Z-Hub/Z-Push/pull/100).                                                                                                 |
| `caldav-windows-timezone-names.patch`           | Submit  | Strong generic fix that reuses Z-Push's existing Windows-to-IANA map instead of ambiguous bias matching. Existing issue [#39](https://github.com/Z-Hub/Z-Push/issues/39) explicitly left the door open to a tested fix. Add named-zone, NUL-padded-name, ambiguous-offset, and unknown-name tests.                                                                    |
| `caldav-preserve-fixed-offset-timezone.patch`   | Prepare | Correctly preserves whole-hour fixed offsets with POSIX-inverted `Etc/GMT` names, but replaces the entire legacy transition search. Retain the named/DST fallback for clients without usable timezone names, then add positive/negative/fractional-offset tests.                                                                                                      |
| `caldav-response-filter.patch`                  | Prepare | Missing `href`/`etag` guards prevent phantom collection rows, but blanket filtering can also discard deletion tombstones that legitimately lack an etag. Model success rows, collection rows, and deleted-resource responses separately before upstreaming.                                                                                                           |
| `caldav-organizer-attendee-normalization.patch` | Prepare | Split into organizer-name hydration and organizer-as-attendee suppression. The first is generally useful with tests for empty/local-part/email-shaped names. The second is client policy and should be independently configurable, not silently applied to every local organizer.                                                                                     |
| `imap-meetingresponse-caldav-flag.patch`        | Prepare | Small, generic separation between CalDAV writes caused by an explicit meeting response and broad mail-side calendar ingestion. Add config documentation and tests proving ordinary inbound iMIP remains disabled while an explicit response can write.                                                                                                                |
| `imap-suppress-calendar-sendmail.patch`         | Local   | Abird-specific single-scheduling-owner policy. It returns success while dropping the client's outbound scheduling mail, which is dangerous outside a server-side scheduling deployment. Do not upstream as written. A future generic hook would need explicit configuration, audit logging, and proof that the calendar write/scheduling transaction succeeded first. |

## MiroFish

`helper.sh` should be treated as several patches, not one upstream change. The
upstream pin still equals current `main`, so none of these local modifications
have landed there.

| Scripted change                                    | Class         | Assessment                                                                                                                                                                                                                                             |
| -------------------------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Vite `allowedHosts`/preview configuration          | Track / Local | Do not duplicate open PR [#344](https://github.com/666ghj/MiroFish/pull/344) for configurable allowed hosts. `open: false` and a fixed preview port are deployment packaging unless expressed as normal environment-backed upstream options.           |
| Default locale and API timeout                     | Prepare       | Environment-backed `VITE_DEFAULT_LOCALE` and `VITE_API_TIMEOUT_MS` are generic. Split them from Abird's hardcoded English HTML metadata. Coordinate with the many existing i18n PRs instead of adding another broad locale PR.                         |
| Optional `LLM_REASONING_EFFORT`                    | Submit        | Useful provider-neutral configuration if only sent to compatible APIs. Centralize request construction so all call sites behave consistently and add tests for unset/set values and providers that reject the field.                                   |
| Environment-backed chunk size/overlap              | Prepare       | Generic operator tuning, but it is a feature. Add validation and document safe bounds; do not mix it with graph failure handling.                                                                                                                      |
| Episode timeout and terminal failure propagation   | Submit        | Strong bug fix: a timeout should fail instead of silently breaking with partial graph state, and terminal task failures should not be swallowed as transient lookup errors. Add timeout, partial-success, terminal-failure, and transient-retry tests. |
| Graph tasks response without duplicate `to_dict()` | Track         | Existing PRs [#305](https://github.com/666ghj/MiroFish/pull/305) and [#667](https://github.com/666ghj/MiroFish/pull/667) cover this exact crash. Keep the local workaround until one lands; do not submit a third duplicate.                           |

Convert each selected MiroFish substitution into a normal source commit. The
current Perl/string replacement approach is useful for packaging but too brittle
to review or rebase upstream.

## Kanidm

The overlay contains two different product decisions:

- Self-service application-password management is a legitimate upstream feature
  proposal. Kanidm already has the SCIM/server capability, but the current Abird
  implementation injects JavaScript into changing upstream DOM. Propose the UX
  and privilege model upstream, then implement it natively in the maintained UI
  if accepted. Do not submit `app-passwords.js` as-is.
- App-link ordering, custom groups, Abird labels, and injected CSS are Abird
  portal policy. Keep `app-links.js`, generated app metadata, and styling local.

## Packaging-Only Rewrites

These should not be sent to the application repositories:

- Bulwarkmail: local Geist fonts and webpack selection for Nix sandbox builds.
- VS Code: replace the bundled ripgrep path with the Nix-store ripgrep path.
- Zed: rewrite desktop `TryExec`/`Exec` to the wrapped Nix-store executable.

If the corresponding nixpkgs packages still need these changes, audit them
against current nixpkgs and upstream there as packaging fixes instead.

## Validation Performed

- Enumerated every repo `.patch`/`.diff` outside worktrees and every source
  rewrite under `pkgs/ext` and `lib/ext`.
- Traced each explicit patch to its Nix consumer and active Abird configuration
  flags.
- Compared pinned sources with current upstream default branches, releases,
  history, issues, PRs, and contribution policies.
- Ran forward and reverse `git apply --check` probes against refreshed upstream
  clones. Apply status was used only as rebase evidence, not as proof of
  semantic upstreamability.
- The audit itself made no package or runtime changes. The approved follow-up
  created seven isolated upstream commits, pushed seven fork branches, and
  opened Z-Push draft PRs #194 and #195. No Stalwart PR was opened because the
  submitting account is not on the repository's current author allowlist.
