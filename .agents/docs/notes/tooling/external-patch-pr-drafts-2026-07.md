# External Patch Upstream PR Drafts — 2026-07

## Status

Implementation and publication pass completed on 2026-07-14.

| Target   | Title                                                                   | Published result                                                                                                  |
| -------- | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Stalwart | Uppercase MAILTO calendar addresses become invalid SMTP recipients      | [fork branch](https://github.com/prasannavl/stalwart/tree/agent/calendar-mailto-normalization), commit `200ffda0` |
| Stalwart | DMARC is skipped when MAIL FROM SPF is unavailable                      | [fork branch](https://github.com/prasannavl/stalwart/tree/agent/dmarc-without-mail-from-spf), commit `c713a673`   |
| Stalwart | Pipelined IMAP STORE can be overtaken by EXPUNGE                        | [fork branch](https://github.com/prasannavl/stalwart/tree/agent/imap-store-pipeline-order), commit `9042b0fd`     |
| Stalwart | IMAP IDLE sends STATUS for the selected mailbox before EXISTS and FETCH | [fork branch](https://github.com/prasannavl/stalwart/tree/agent/imap-idle-selected-mailbox), commit `db50aa08`    |
| Stalwart | Floating calendar times can render as an unrelated IANA timezone        | [fork branch](https://github.com/prasannavl/stalwart/tree/agent/calendar-floating-timezone), commit `74d6d28f`    |
| Z-Push   | Extensionless CardDAV contacts are omitted from sync results            | [draft PR #194](https://github.com/Z-Hub/Z-Push/pull/194), commit `1c63180c`                                      |
| Z-Push   | ActiveSync calendar writes ignore explicit Windows timezone names       | [draft PR #195](https://github.com/Z-Hub/Z-Push/pull/195), commit `168627f1`                                      |

The Z-Push PRs are open as drafts for human review. The Stalwart branches are
pushed but intentionally not opened as PRs: the authenticated GitHub account
`prasannavl` is not in Stalwart's current
[`allowed-pr-authors.txt`](https://github.com/stalwartlabs/stalwart/blob/main/.github/allowed-pr-authors.txt),
so the repository automation would close those PRs. Use the branch diffs for
support/vouching and open the PRs only after the author is allowed and the FLA
path is confirmed.

Validation completed:

- `cargo fmt --all -- --check` and `git diff --check` on all five Stalwart
  branches.
- Focused `groupware` unit tests for MAILTO normalization and floating timezone
  serialization.
- Focused SQLite SMTP integration test for DMARC without MAIL FROM SPF.
- Complete SQLite IMAP suite on both the STORE-ordering and IDLE branches.
- PHP 8.4.23 syntax checks for both Z-Push changes.
- Direct Windows-name resolver checks and a full decoded ActiveSync timezone
  blob check for `W. Europe Standard Time` -> `Europe/Amsterdam`.

The drafts target the seven highest-confidence candidates from the external
patch audit. They are written against these upstream snapshots:

- Stalwart `45602a35ba1cbec189ae4468019063417f371b4f` from 2026-07-14.
- Z-Push `develop` at `659ecf897d1b1f37c90098dd4ae73237a1cf37ac`.

Before submission, each local patch still needs to be recreated as a clean
commit on the target upstream branch, supplied with the tests described below,
and validated there. Do not claim planned tests as completed tests.

## Integration Context

The patches came from operating a deliberately mixed mail and groupware stack:

```text
Kanidm identity and per-application passwords
                     |
                     v
Stalwart mail, IMAP, JMAP, CalDAV, CardDAV, and scheduling
        |                  |                    |
        v                  v                    v
Bulwarkmail/JMAP     native IMAP clients    Z-Push/ActiveSync
calendar and mail    Thunderbird, Geary     Gmail Android, iOS,
                                           Outlook/Exchange-style clients
        |
        v
iTIP/iMIP to external calendar systems and SMTP providers
Google Calendar, Gmail reports, Brevo relay, and other domains
```

This topology is useful upstream evidence because it exercises protocol seams,
not private APIs. Kanidm supplies identities and application passwords, but
Stalwart remains the mail and calendar source of truth. Bulwarkmail is a JMAP
client. Z-Push translates Exchange ActiveSync into Stalwart IMAP, CalDAV, and
CardDAV. External Gmail, Google Calendar, Exchange/Outlook, and SMTP-provider
traffic then expose assumptions that do not appear in a single-vendor setup.

The PRs should describe this as the reproducing environment, not as a reason to
add Abird-specific behavior. Each proposed fix is at the generic protocol
boundary where the invalid assumption occurs.

## Submission Order and Gates

| Order | Target   | Draft                                        | Gate before submission                                                    |
| ----: | -------- | -------------------------------------------- | ------------------------------------------------------------------------- |
|     1 | Stalwart | Case-insensitive `mailto:` normalization     | Focused unit tests; support topic; vouching; FLA                          |
|     2 | Stalwart | DMARC without a MAIL FROM SPF result         | Rebase on current DMARCbis code; SMTP tests; support topic; vouching; FLA |
|     3 | Stalwart | Serialize pipelined IMAP STORE               | Integration reproducer; support topic; vouching; FLA                      |
|     4 | Stalwart | Correct selected-mailbox IDLE updates        | Preserve Brock Tice authorship; resolve FLA path; support follow-up       |
|     5 | Stalwart | Avoid a false IANA zone for floating times   | Scheduling snapshot regression test; support topic; vouching; FLA         |
|     6 | Z-Push   | Request CardDAV content type in sync reports | Fixture/manual sync validation; AGPL statement                            |
|     7 | Z-Push   | Prefer explicit Windows timezone names       | Named/fallback timezone tests; AGPL statement                             |

Stalwart's current contribution policy requires a support discussion and a vouch
before a PR can be opened. It accepts bug fixes, requires small focused changes,
an FLA, and human ownership of every submitted line. The text under each
Stalwart draft can serve as both the support proposal and, after vouching, the
eventual PR body. Add the support URL and clean branch URL before opening the
PR.

The Z-Push drafts follow its repository PR template and include the mandatory
AGPLv3 release statement.

---

## Stalwart Draft 1: Normalize `mailto:` Case-Insensitively

### Proposed issue/PR title

`Uppercase MAILTO calendar addresses become invalid SMTP recipients`

### Suggested commit subject

`fix(groupware): normalize mailto calendar addresses case-insensitively`

### Support topic and eventual PR draft

#### Issue

iCalendar calendar addresses are URIs. In practice, calendar producers emit both
`mailto:user@example.net` and `MAILTO:user@example.net`.

Stalwart's scheduling `Email::new()` currently removes only the exact lowercase
prefix before lowercasing the remaining string:

```rust
email.trim().trim_start_matches("mailto:").to_lowercase()
```

For an uppercase or mixed-case scheme, lowercasing happens too late. The result
is not the mailbox `user@example.net`; it is the invalid SMTP recipient
`mailto:user@example.net`.

#### Reproduction

1. Process an iTIP object containing an address such as:

   ```text
   ATTENDEE:MAILTO:user@example.net
   ```

2. Let Stalwart generate an iMIP scheduling message for that attendee.
3. Observe the SMTP envelope recipient.

Expected:

```text
RCPT TO:<user@example.net>
```

Actual:

```text
RCPT TO:<mailto:user@example.net>
```

We found this during calendar cancellation delivery through Stalwart. The
outbound Brevo smarthost correctly rejected the malformed envelope recipient.
The same failure is possible with any strict SMTP relay; Brevo is only where it
became visible.

#### Why this is a bug

URI schemes are case-insensitive under RFC 3986. RFC 5545 models organizer and
attendee values as calendar-address URIs and uses `mailto:` addresses throughout
its scheduling examples. Treating `MAILTO:` differently from `mailto:` turns a
valid calendar address into an invalid SMTP mailbox.

- RFC 3986 scheme normalization:
  <https://datatracker.ietf.org/doc/html/rfc3986#section-6.2.2.1>
- RFC 5545 attendee examples:
  <https://datatracker.ietf.org/doc/html/rfc5545#section-3.8.4.1>

#### Proposed change

Inspect the first seven bytes case-insensitively, remove them only when they are
the `mailto:` scheme, then trim and lowercase the bare address. This keeps the
existing normalization behavior for normal addresses while accepting upper- and
mixed-case URI schemes.

The change is intentionally local to scheduling address normalization. It does
not alter SMTP address parsing or introduce provider-specific handling.

#### Test plan

Add focused cases for:

- `mailto:user@example.net`
- `MAILTO:user@example.net`
- `MaIlTo:user@example.net`
- surrounding whitespace
- a bare `user@example.net` address
- a non-prefix occurrence that must not be removed

Then run:

```sh
cargo fmt --all --check
cargo test -p tests jmap -- --nocapture
cargo test -p tests smtp -- --nocapture
```

#### Submission metadata

- Support discussion: `[create after human review]`
- Clean diff/branch:
  <https://github.com/stalwartlabs/stalwart/compare/main...prasannavl:agent/calendar-mailto-normalization>
- Reproduced with: Stalwart `0.16.x`, JMAP/iTIP scheduling, Brevo SMTP relay

---

## Stalwart Draft 2: Run DMARC When MAIL FROM SPF Is Unavailable

### Proposed issue/PR title

`DMARC is skipped when MAIL FROM SPF is unavailable`

### Suggested commit subject

`fix(smtp): evaluate DMARC when MAIL FROM SPF is unavailable`

### Support topic and eventual PR draft

#### Issue

Stalwart currently enters DMARC verification only when `self.data.spf_mail_from`
is `Some(...)`. If a message has no stored MAIL FROM SPF result, DMARC is
skipped entirely, including DKIM alignment.

That makes the presence of one authentication mechanism a prerequisite for
evaluating the other. A message with an aligned, valid DKIM signature can
therefore receive no DMARC result simply because MAIL FROM SPF was unavailable.

#### Reproduction

We observed this with a legitimate Gmail SMTP TLS report:

```text
From: noreply-smtp-tls-reporting@google.com
DKIM-Signature: ... d=google.com ...
```

The message had an aligned DKIM pass, while the MAIL FROM SPF result was absent
in the Stalwart session state. Stalwart skipped DMARC rather than allowing the
DKIM-authenticated identifier to satisfy DMARC.

A focused reproducer is:

1. Enable DKIM and DMARC verification.
2. Submit a message with an RFC5322.From domain that publishes DMARC.
3. Provide a valid, aligned DKIM signature.
4. Exercise the path where no MAIL FROM SPF output is stored.
5. Inspect the DMARC result and `Authentication-Results`.

Expected: DMARC is evaluated and passes through aligned DKIM.

Actual: DMARC evaluation is not run because `spf_mail_from` is `None`.

#### Why this is a bug

DMARC supports authenticated identifiers from both DKIM and SPF. RFC 9989 says
that a message passes when one or more authenticated identifiers align with the
Author Domain. It does not require an SPF result to exist before aligned DKIM
can be evaluated.

- DMARC authentication mechanisms:
  <https://datatracker.ietf.org/doc/html/rfc9989#section-4.3>
- DMARC pass/fail determination:
  <https://datatracker.ietf.org/doc/html/rfc9989#section-5.3.5>

This matters especially for null-sender and operational-report traffic, but the
bug is not specific to Gmail reports. The general invariant is that unavailable
SPF must not suppress a valid DKIM-based DMARC result.

#### Proposed change

When DMARC verification is enabled, always call the DMARC verifier. If no MAIL
FROM SPF output is available, pass a neutral SPF `None` result using the
effective RFC5321 identity expected by the current `mail-auth` API. Do not emit
an SPF pass, and do not add an SPF `Authentication-Results` entry that was not
actually evaluated.

The current local patch demonstrates the behavior, but it must be rebased on
Stalwart's current `mail-auth` 0.11/DMARCbis code. The rebased implementation
should use the effective MAIL FROM identity consistently, including the
null-path/HELO case, rather than copying the old patch mechanically.

#### Security and compatibility

- This does not weaken DMARC: missing SPF remains `None`, not `Pass`.
- Aligned DKIM is still cryptographically verified before it can satisfy DMARC.
- DKIM failure with no SPF pass still produces DMARC failure.
- Existing behavior is unchanged when a MAIL FROM SPF output is present.

#### Test plan

Add SMTP integration cases for:

- SPF unavailable, aligned DKIM pass: DMARC pass.
- SPF unavailable, DKIM fail: DMARC fail.
- SPF unavailable, DKIM unaligned pass: DMARC fail.
- null reverse-path with aligned DKIM.
- existing SPF pass/fail paths to prevent regressions.
- no synthetic SPF result in `Authentication-Results` when SPF was not run.

Then run:

```sh
cargo fmt --all --check
cargo test -p tests smtp -- --nocapture
```

#### Submission metadata

- Support discussion: `[create after human review]`
- Clean diff/branch:
  <https://github.com/stalwartlabs/stalwart/compare/main...prasannavl:agent/dmarc-without-mail-from-spf>
- Reproduced with: Stalwart `0.16.x`, Gmail TLS reporting message

---

## Stalwart Draft 3: Serialize Pipelined STORE Before EXPUNGE

### Proposed issue/PR title

`Pipelined IMAP STORE can be overtaken by EXPUNGE`

### Suggested commit subject

`fix(imap): complete STORE before processing pipelined commands`

### Support topic and eventual PR draft

#### Issue

Stalwart handles IMAP STORE with `spawn_op!`, so the command handler returns
before the flag update is committed. A following pipelined command can run
against the old mailbox state even though the client sent STORE first.

The visible failure is a standard delete sequence:

```text
C: A1 UID STORE 266 +FLAGS.SILENT (\Deleted)
C: A2 UID EXPUNGE 266
```

`UID EXPUNGE` can complete before the spawned STORE operation has committed the
`\Deleted` flag. It then finds nothing to expunge.

#### Production trace

We diagnosed this after messages deleted in Geary reappeared in INBOX. A
Stalwart protocol trace showed:

```text
STORE [266] +FLAGS \Deleted
EXPUNGE documentId=[]
```

Reviewing Geary's client code and the wire ordering confirmed that Geary sent
STORE before EXPUNGE as one pipelined batch. The race was server-side:

- `handle_store()` detached the mutation with `spawn_op!`.
- `handle_expunge()` ran inline and awaited its mailbox query.
- the EXPUNGE query could therefore overtake the earlier STORE commit.

This is not specific to Geary. Any client that pipelines a flag-changing STORE
with a dependent command can observe the same ordering violation.

#### Why this is a bug

RFC 9051 section 5.5 allows command pipelining but requires commands that can
affect each other's results to execute to completion in client order. STORE
changes the exact `\Deleted` state on which EXPUNGE depends.

<https://datatracker.ietf.org/doc/html/rfc9051#section-5.5>

The same rule protects other dependent STORE pipelines, such as a STORE that
sets `\Seen` followed by a search whose result depends on that flag.

#### Proposed change

Await `data.store(...)` directly in `handle_store()` and write its response
before returning, instead of dispatching it through `spawn_op!`. Remove the
unused macro import.

This aligns STORE with the inline execution already used for EXPUNGE and CLOSE.
It preserves pipelined input but prevents later commands from overtaking the
state mutation.

#### Performance and compatibility

The change intentionally gives up concurrent execution only within a single IMAP
connection where command ordering is observable. Independent sessions remain
concurrent. Correct ordering is more important than allowing dependent commands
on one connection to race.

#### Test plan

Add an integration test that sends STORE and UID EXPUNGE in a single pipelined
write, then asserts:

- STORE completes successfully.
- EXPUNGE removes the target message.
- a subsequent search does not return the message.
- a non-target message remains present.

Also cover a STORE followed by a dependent flag query if the existing IMAP test
harness makes that inexpensive.

Then run:

```sh
cargo fmt --all --check
cargo test -p tests imap -- --nocapture
```

#### Submission metadata

- Support discussion: `[create after human review]`
- Clean diff/branch:
  <https://github.com/stalwartlabs/stalwart/compare/main...prasannavl:agent/imap-store-pipeline-order>
- Reproduced with: Stalwart `0.16.x`, RocksDB, Geary IMAP client

---

## Stalwart Draft 4: Correct Selected-Mailbox Updates During IDLE

### Proposed issue/PR title

`IMAP IDLE sends STATUS for the selected mailbox before EXISTS and FETCH`

### Suggested commit subject

`fix(imap): avoid unsolicited STATUS for the selected mailbox during IDLE`

### Authorship gate

This work is not solely ours. Brock Tice authored the original reproducer and
branch:

- Support topic:
  <https://support.stalw.art/t/fixed-imap-idle-not-sending-exists-when-it-should-cant-issue-pr-on-github/339>
- Original commit:
  <https://github.com/brocktice/stalwart/commit/d7ed3101193eecdbc8b5a31dcbe1d42dcf26d2cc>

Our local patch builds on that work and incorporates the Stalwart maintainer's
feedback: do not merely reorder the selected mailbox's unsolicited STATUS; omit
it and use selected-state EXISTS, EXPUNGE, and FETCH updates.

Before submission, preserve Brock's authorship in Git history and confirm the
FLA path with Brock and the Stalwart maintainer. If that cannot be arranged, ask
the maintainer to implement or cherry-pick the accepted shape rather than
submitting the combined patch under a single different author.

### Support follow-up and eventual PR draft

#### Issue

During IDLE, a delivery or mutation affecting the currently selected mailbox can
cause Stalwart to emit an unsolicited STATUS for that same mailbox before the
selected-state EXISTS/FETCH updates.

Although robust clients may tolerate this sequence, RFC 9051 describes STATUS as
a way to inspect mailboxes other than the selected mailbox and says it must not
be used to check the selected mailbox for new messages. The correct
selected-state notifications are EXISTS, EXPUNGE, and FETCH.

In our deployment, Thunderbird held a healthy IDLE connection but discovered new
mail only on its periodic polling cadence. Geary and the Android ActiveSync path
saw the delivery promptly. The differentiating server response was the
selected-mailbox STATUS sequence.

#### Reproduction

1. Authenticate over IMAP.
2. `SELECT INBOX` and enter `IDLE`.
3. Deliver a message to that INBOX over SMTP or LMTP.
4. Observe the IDLE connection.

Expected:

```text
* 1 EXISTS
* 1 FETCH (FLAGS (...) UID ...)
```

There should be no unsolicited `STATUS "INBOX"` used as the change signal for
the selected mailbox.

Actual: Stalwart can send STATUS for INBOX before the selected-state updates;
some clients do not wake correctly and discover the message only during their
next poll.

#### Standards case

- RFC 9051 STATUS guidance:
  <https://datatracker.ietf.org/doc/html/rfc9051#section-6.3.11>
- RFC 9051 IDLE selected-state updates:
  <https://datatracker.ietf.org/doc/html/rfc9051#section-6.3.13>
- RFC 9051 EXISTS semantics:
  <https://datatracker.ietf.org/doc/html/rfc9051#section-7.4.1>

#### Proposed change

- Synchronize selected-mailbox email changes through the existing
  `write_mailbox_changes()` and FETCH path.
- When serializing general mailbox changes, resolve the selected mailbox ID and
  skip STATUS for that mailbox.
- Continue emitting STATUS for changed non-selected mailboxes.
- Avoid early returns that would suppress independent non-selected mailbox
  updates.

For the first upstream PR, keep the change focused on selected-mailbox STATUS
suppression and notification flow. The local addition of HIGHESTMODSEQ to
non-selected STATUS responses under CONDSTORE is useful but separable and should
not enlarge this bug fix unless the maintainer explicitly requests it.

#### Test plan

Extend the existing IMAP IDLE integration test to assert:

- SMTP/LMTP delivery to the selected mailbox produces EXISTS and FETCH.
- the selected mailbox does not produce unsolicited STATUS.
- a changed non-selected mailbox still produces STATUS.
- deletion from the selected mailbox produces EXPUNGE/EXISTS updates.
- the behavior works with and without CONDSTORE/QRESYNC enabled.

Then run:

```sh
cargo fmt --all --check
cargo test -p tests imap -- --nocapture
```

#### Submission metadata

- Existing support discussion:
  <https://support.stalw.art/t/fixed-imap-idle-not-sending-exists-when-it-should-cant-issue-pr-on-github/339>
- Revised clean branch:
  <https://github.com/stalwartlabs/stalwart/compare/main...prasannavl:agent/imap-idle-selected-mailbox>
- Reproduced with: Stalwart `0.16.x`, Thunderbird and Geary
- Original work: Brock Tice
- Follow-up implementation and production validation: Prasanna Loganathar

---

## Stalwart Draft 5: Do Not Serialize Floating Time as an IANA Zone

### Proposed issue/PR title

`Floating calendar times can render as an unrelated IANA timezone`

### Suggested commit subject

`fix(groupware): avoid false timezone labels for floating calendar times`

### Support topic and eventual PR draft

#### Issue

An iCalendar DATE-TIME without `TZID` and without the UTC `Z` suffix is a
floating time. Stalwart correctly resolves that value through its floating-time
sentinel while constructing a scheduling snapshot, but then serializes the
sentinel's numeric ID into `ItipDateTime.tz_code` as though it identified a real
IANA timezone.

Downstream summary rendering can interpret that numeric ID as an unrelated zone.
In our case, a Bulwarkmail-created floating event produced an iMIP summary
labelled `Antarctica/Casey`.

#### Reproduction

1. Create or import an event with a floating start time:

   ```text
   DTSTART:20260715T090000
   DTEND:20260715T100000
   ```

2. Let Stalwart create the iTIP scheduling snapshot and render an iMIP summary.
3. Inspect the timezone used for summary formatting.

Expected: the floating sentinel must not be exposed as a real IANA timezone.

Actual: its numeric ID can be decoded as an unrelated named zone, producing a
false label and potentially a misleading summary.

#### Why this is a bug

RFC 5545 defines local DATE-TIME values without `TZID` as floating and
explicitly says they are not bound to any particular timezone.

<https://datatracker.ietf.org/doc/html/rfc5545#section-3.3.5>

The internal floating sentinel is therefore type information, not an IANA zone
identifier. Serializing it through the same numeric field as a named zone loses
that distinction.

#### Proposed change

When the resolved timezone is floating, store a safe UTC code in the internal
snapshot field used by the current summary renderer; otherwise preserve the
resolved timezone ID. Keep the existing timestamp calculation unchanged.

The local patch is deliberately small, but the regression test should document
that this is an internal rendering fallback, not a claim that the source event
was UTC. If the maintainers prefer, a stronger long-term representation would
make `tz_code` distinguish floating explicitly rather than overloading a numeric
zone ID. The small fix prevents the current false-IANA-zone behavior without
changing stored calendar data.

#### Test plan

Add scheduling snapshot cases for:

- floating DATE-TIME: no unrelated IANA zone is serialized.
- explicit UTC DATE-TIME: UTC remains UTC.
- named `TZID`: the named zone ID remains unchanged.
- a recurrence or end time using the same floating path.

Then run:

```sh
cargo fmt --all --check
cargo test -p tests jmap -- --nocapture
```

If the appropriate coverage belongs in the WebDAV scheduling suite, also run:

```sh
cargo test -p tests webdav -- --nocapture
```

#### Submission metadata

- Support discussion: `[create after human review]`
- Clean diff/branch:
  <https://github.com/stalwartlabs/stalwart/compare/main...prasannavl:agent/calendar-floating-timezone>
- Reproduced with: Stalwart `0.16.x`, Bulwarkmail/JMAP event creation, iMIP

---

## Z-Push Draft 1: Request Content Type During CardDAV Sync

### Proposed issue/PR title

`Extensionless CardDAV contacts are omitted from sync results`

### Suggested commit subject

`fix(carddav): request getcontenttype in sync reports`

### Copy-ready PR body

Released under the GNU Affero General Public License (AGPL), version 3

#### What does this implement/fix? Explain your changes

This adds `DAV:getcontenttype` to the property list requested by CardDAV
`sync-collection` REPORTs.

Z-Push's existing CardDAV response parser recognizes a response as a vCard when
one of these is true:

- the href has the configured vCard extension;
- `getcontenttype` contains `vcard`; or
- the REPORT embeds `address-data`/`addressbook-data`.

The sync REPORT currently requests `getetag` and `getlastmodified`, but not
`getcontenttype`. That leaves extensionless CardDAV resources impossible to
classify when the server does not embed the vCard body.

We reproduced this with Stalwart CardDAV behind Z-Push's `BackendCombined` and
the Gmail app on Android:

1. Stalwart returned successful, non-empty `207 Multi-Status` sync responses.
2. Contact hrefs were valid but extensionless, for example
   `/dav/card/user@example.net/default/<id>`.
3. The sync response did not include embedded card data.
4. Z-Push logged zero contact changes and exported an empty contact set to a
   freshly provisioned device.
5. Other CardDAV clients, including Thunderbird, GNOME Contacts, and a JMAP
   webmail client, saw the server contacts correctly.

Requesting `getcontenttype` lets the existing parser classify
`text/vcard`/`text/x-vcard` responses without inventing a filename convention or
adding server-specific code. It works for initial and incremental native sync.

This complements the earlier collection-filtering work in PR #100. That change
prevents an address-book collection from being mistaken for a vCard; this change
ensures actual extensionless vCard resources carry the property the same parser
already expects.

Related:

- <https://github.com/Z-Hub/Z-Push/pull/100>
- WebDAV sync-collection:
  <https://datatracker.ietf.org/doc/html/rfc6578#section-3.2>

#### Does this close any currently open issues?

No known open issue. This fixes extensionless native CardDAV sync against
servers such as Stalwart.

#### Any relevant logs, error output, etc?

Before the change, the CardDAV server returned non-empty 207 REPORT bodies while
Z-Push logged:

```text
ExportChangesDiff->InitializeExporter(): Found '0' changes for 'contacts'
```

After requesting `getcontenttype`, the existing simplifier recognizes the
extensionless responses as vCards and the contacts enter the ActiveSync change
set.

#### Where has this been tested?

Server:

- OS: NixOS
- PHP Version: 8.4.23
- Backend for: Stalwart CardDAV through BackendCombined
- Backend version: Stalwart `0.16.x`; Z-Push `2.7.6`

Smartphone:

- Device: Android phone
- OS: production reproducer version not recorded
- Mail App: Gmail
- Version: production reproducer version not recorded

Validation to complete on the rebased branch:

- extensionless response with `getcontenttype: text/vcard` is included;
- normal `.vcf` href behavior remains unchanged;
- an address-book collection is still excluded as established by PR #100;
- incremental sync behaves the same as initial sync;
- PHP syntax/static checks pass.

---

## Z-Push Draft 2: Prefer Explicit Windows Timezone Names

### Proposed issue/PR title

`ActiveSync calendar writes ignore explicit Windows timezone names`

### Suggested commit subject

`fix(caldav): prefer Windows timezone names over offset guessing`

### Copy-ready PR body

Released under the GNU Affero General Public License (AGPL), version 3

#### What does this implement/fix? Explain your changes

This makes `BackendCalDAV::tzidFromMSTZ()` use the explicit Windows standard or
daylight timezone name carried in an ActiveSync timezone blob before falling
back to the existing bias/transition matcher.

The current code unpacks `tzname` and `tznamedst`, but ignores both. It builds a
key from numeric bias and transition fields, then scans PHP's IANA timezone list
for a matching offset/transition pattern.

That fallback is necessarily ambiguous. Many regions share the same offset and
DST shape. A no-DST UTC+08 payload, for example, does not by itself distinguish
Singapore from every historical IANA region that matched that offset in the
event year. The first enumeration match can therefore be geographically
unrelated, such as `Antarctica/Casey`.

The ActiveSync payload often already contains the missing identity, such as
`Singapore Standard Time`, `India Standard Time`, or `W. Europe Standard Time`.
Z-Push also already maintains the corresponding Windows-to-IANA candidates in
`TimezoneUtil::$phptimezones`; the CalDAV writer simply does not consult that
map.

The proposed change:

1. strips NUL padding and whitespace from `tzname` and `tznamedst`;
2. resolves a recognized Windows name through the existing Windows-to-PHP/IANA
   map;
3. returns the first candidate supported by the running PHP timezone database;
4. preserves the current numeric bias/transition algorithm as the fallback for
   empty or unknown names.

This is more precise when a client supplies an explicit name and no less
compatible when it does not.

The scenario occurs in both directions of Microsoft interoperability:

- ActiveSync clients send the Windows timezone structure to Z-Push when creating
  a calendar item.
- Exchange/Outlook ecosystems commonly preserve Windows timezone names when
  calendars cross into CalDAV. Existing issue #39 documents
  `W. Europe Standard Time` from Exchange/Outlook and the maintainer explicitly
  invited a tested Z-Push fix. The current local patch resolves names already
  present in `$phptimezones`, such as `W Europe Standard Time`; it still needs
  an alias test and normalization for the dotted `W. Europe Standard Time`
  spelling before it can claim to cover that issue's exact payload.

Microsoft's ActiveSync documentation explains why the originator's timezone is
material for recurring meetings across daylight transitions:

<https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-asdtype/df0e20c1-19d0-491f-b7cc-39ce244cda81>

Related issue:

<https://github.com/Z-Hub/Z-Push/issues/39>

#### Does this close any currently open issues?

Issue #39 is closed after a client-side workaround. This PR addresses the same
class of server-side mapping bug, but it should only claim to fix the issue
after adding and testing its exact dotted `W. Europe Standard Time` alias.

#### Any relevant logs, error output, etc?

Before the change, logs can show a timezone selected only from the known numeric
key or PHP transition scan, even though the decoded ActiveSync blob includes a
usable Windows name. The resulting CalDAV `TZID` can identify an unrelated
region with coincident offsets.

After the change, a payload named `Singapore Standard Time` resolves through
Z-Push's existing map to a PHP-supported Singapore IANA zone. Unknown or empty
names continue through the original fallback.

#### Where has this been tested?

Server:

- OS: NixOS
- PHP Version: 8.4.23
- Backend for: Stalwart CalDAV through BackendCombined
- Backend version: Stalwart `0.16.x`; Z-Push `2.7.6`

Smartphone/client:

- Device/client: Android phone from the production reproducer
- OS: production reproducer version not recorded
- Mail/calendar app: Gmail, Outlook, or other reproducing ActiveSync client
- Version: production reproducer version not recorded

Validation to complete on the rebased branch:

- `Singapore Standard Time` resolves to a supported Singapore IANA zone;
- both `W Europe Standard Time` and the documented `W. Europe Standard Time`
  alias resolve to a supported European IANA zone;
- a NUL-padded Windows name is normalized correctly;
- a DST-observing named zone resolves through its name rather than an ambiguous
  offset match;
- an unknown name retains the current bias/transition fallback;
- an empty name retains the current fallback;
- ambiguous offset-only payloads behave exactly as before;
- PHP syntax/static checks pass.

## Remaining Submission Gates

1. Choose the Stalwart support-topic order and obtain a maintainer vouch for
   `prasannavl` before opening any of the five PRs.
2. Confirm FLA coverage for each Stalwart author. The IDLE commit preserves
   Brock Tice as the Git author and still requires his FLA path to be resolved.
3. The floating-time branch intentionally retains the small UTC-code fallback;
   raise an explicit floating representation only if maintainers prefer the
   larger model change.
4. The IDLE branch is narrowed to selected-mailbox STATUS suppression. It does
   not include the separable HIGHESTMODSEQ enhancement.
5. Z-Push PR #195 includes and validates the dotted `W. Europe Standard Time`
   alias. It cites closed issue #39 as related rather than claiming to close it.
