use std::env;
use std::io::{self, IsTerminal};

const RESET: &str = "\x1b[0m";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Tone {
    Success,
    Failure,
    FailureDetail,
    Warning,
    LogWarning,
    Active,
    Label,
    Emphasis,
    Muted,
    Neutral,
}

impl Tone {
    fn code(self) -> &'static str {
        match self {
            Self::Success => "\x1b[32m",
            Self::Failure => "\x1b[31m",
            Self::FailureDetail => "\x1b[31m",
            Self::Warning => "\x1b[33m",
            // Milder amber for streamed child-process warnings, matching
            // nixbot's `_NIXBOT_C_YELLOW` (256-color 178).
            Self::LogWarning => "\x1b[38;5;178m",
            Self::Active => "\x1b[36m",
            Self::Label => "\x1b[34m",
            Self::Emphasis => "\x1b[1m",
            Self::Muted => "\x1b[2m",
            Self::Neutral => "\x1b[90m",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TerminalStyle {
    enabled: bool,
}

impl TerminalStyle {
    pub fn for_stdout() -> Self {
        Self::from_capabilities(
            io::stdout().is_terminal() || color_forced_by_environment(),
            color_disabled_by_environment(),
        )
    }

    pub fn for_stderr() -> Self {
        Self::from_capabilities(
            io::stderr().is_terminal() || color_forced_by_environment(),
            color_disabled_by_environment(),
        )
    }

    pub fn from_capabilities(is_terminal: bool, color_disabled: bool) -> Self {
        Self {
            enabled: is_terminal && !color_disabled,
        }
    }

    pub fn enabled(self) -> bool {
        self.enabled
    }

    pub fn paint(self, tone: Tone, value: impl AsRef<str>) -> String {
        let value = value.as_ref();
        if self.enabled {
            format!("{}{value}{RESET}", tone.code())
        } else {
            value.to_owned()
        }
    }

    /// Give host identities a stable color from the shared nixbot host palette
    /// so parallel rows stay easy to track. State remains owned by the status
    /// glyph and word; this color only distinguishes one host from another.
    /// Mirrors `host_color_code` in `pkgs/tools/nixbot/nixbot.sh`.
    pub fn paint_host(self, host: &str) -> String {
        if !self.enabled {
            return host.to_owned();
        }
        const HOST_COLORS: [&str; 9] = [
            "\x1b[36m", "\x1b[34m", "\x1b[35m", "\x1b[33m", "\x1b[94m", "\x1b[95m", "\x1b[96m",
            "\x1b[92m", "\x1b[93m",
        ];
        // FNV-1a (32-bit), matching nixbot's host color index. A plain
        // polynomial hash clusters shared host prefixes onto one color.
        let hash = host.bytes().fold(2_166_136_261u32, |hash, byte| {
            (hash ^ u32::from(byte)).wrapping_mul(16_777_619)
        });
        format!(
            "{}{host}{RESET}",
            HOST_COLORS[(hash % HOST_COLORS.len() as u32) as usize]
        )
    }

    pub fn semantic_document(self, document: &str) -> String {
        self.semantic_text_with_heading(document, true)
    }

    pub fn semantic_text(self, text: &str) -> String {
        self.semantic_text_with_heading(text, false)
    }

    fn semantic_text_with_heading(self, text: &str, infer_heading: bool) -> String {
        let mut output = String::with_capacity(text.len());
        let mut first_nonempty = true;
        for segment in text.split_inclusive('\n') {
            let (line, newline) = segment
                .strip_suffix('\n')
                .map_or((segment, ""), |line| (line, "\n"));
            output.push_str(&self.semantic_line(line, infer_heading && first_nonempty));
            output.push_str(newline);
            if !line.is_empty() {
                first_nonempty = false;
            }
        }
        output
    }

    pub fn semantic_line(self, line: &str, heading: bool) -> String {
        if !self.enabled || line.is_empty() {
            return line.to_owned();
        }
        if line.starts_with("✓ ") {
            return self.paint(Tone::Success, line);
        }
        if line.starts_with("✗ ") {
            return self.paint(Tone::Failure, line);
        }
        if line.starts_with("● ") {
            return self.paint(Tone::Active, line);
        }
        if line.starts_with("◇ ")
            || line.starts_with("• Would ")
            || line.starts_with("Dry run")
            || line.starts_with("No changes will be made")
            || line.starts_with("Ready to continue")
            || line.to_ascii_lowercase().starts_with("warning:")
        {
            return self.paint(Tone::Warning, line);
        }
        if heading {
            return self.paint(Tone::Emphasis, line);
        }
        if let Some(separator) = key_value_separator(line) {
            let (key, value) = line.split_at(separator);
            return format!("{}{}", self.paint(Tone::Label, key), value);
        }
        line.to_owned()
    }
}

fn color_disabled_by_environment() -> bool {
    env::var_os("NO_COLOR").is_some()
        || env::var("GITHUB_ACTIONS").as_deref() == Ok("true")
        || env::var_os("TERM")
            .is_some_and(|term| term.to_string_lossy().eq_ignore_ascii_case("dumb"))
}

fn color_forced_by_environment() -> bool {
    env::var("NIXBOT_FORCE_COLOR")
        .ok()
        .is_some_and(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
}

fn key_value_separator(line: &str) -> Option<usize> {
    if line.starts_with(char::is_whitespace) {
        return None;
    }
    let separator = line.find("  ")?;
    let key = &line[..separator];
    (!key.is_empty()
        && key.len() <= 12
        && key
            .chars()
            .all(|character| character.is_alphanumeric() || matches!(character, '-' | '_')))
    .then_some(separator)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_style_preserves_output_byte_for_byte() {
        let style = TerminalStyle::from_capabilities(false, false);
        let document = "✓ Complete\n\nState   target active\n";
        assert_eq!(style.semantic_document(document), document);
        assert!(!style.enabled());
    }

    #[test]
    fn semantic_document_uses_a_small_consistent_palette() {
        let style = TerminalStyle::from_capabilities(true, false);
        let document = style.semantic_document(
            "Migration\n\n✓ Complete\n✗ Failed\n● Running\n◇ Deferred\nState   target active\n",
        );
        assert!(document.contains("\x1b[1mMigration\x1b[0m"));
        assert!(document.contains("\x1b[32m✓ Complete\x1b[0m"));
        assert!(document.contains("\x1b[31m✗ Failed\x1b[0m"));
        assert!(document.contains("\x1b[36m● Running\x1b[0m"));
        assert!(document.contains("\x1b[33m◇ Deferred\x1b[0m"));
        assert!(document.contains("\x1b[34mState\x1b[0m   target active"));
        assert_eq!(document.matches("\x1b[1m").count(), 1);
        assert_eq!(
            style.paint(Tone::Neutral, "skipped"),
            "\x1b[90mskipped\x1b[0m"
        );
    }

    #[test]
    fn host_identity_colors_are_stable_and_spread_across_the_palette() {
        let style = TerminalStyle::from_capabilities(true, false);
        const PALETTE: [&str; 9] = [
            "\x1b[36m", "\x1b[34m", "\x1b[35m", "\x1b[33m", "\x1b[94m", "\x1b[95m", "\x1b[96m",
            "\x1b[92m", "\x1b[93m",
        ];
        assert_eq!(style.paint_host("alpha"), style.paint_host("alpha"));
        assert_eq!(
            TerminalStyle::from_capabilities(false, false).paint_host("alpha"),
            "alpha"
        );

        let hosts = [
            "gap3-gondor",
            "abird-gondor-data",
            "abird-gondor-dev",
            "abird-gondor-id",
            "abird-gondor-obs",
            "abird-gondor-proxy",
            "abird-gondor-srv",
            "abird-gondor-tictactoe",
            "abird-gondor-zulip",
            "abird-gondor-corp",
            "abird-gondor-ci",
        ];
        let mut distinct = std::collections::BTreeSet::new();
        for host in hosts {
            let painted = style.paint_host(host);
            let code = PALETTE
                .iter()
                .find(|code| painted.starts_with(**code))
                .unwrap_or_else(|| panic!("{painted} did not use the host palette"));
            distinct.insert(*code);
        }
        // Regression guard: the shared `abird-gondor-` prefix must not collapse
        // the roster onto one or two identity colors.
        assert!(distinct.len() >= 5, "{distinct:?}");
    }

    #[test]
    fn semantic_text_never_promotes_body_lines_to_headings() {
        let style = TerminalStyle::from_capabilities(true, false);
        let text = "Summary · deploy · success\n  host · ok\n  │ raw process output\n";
        assert_eq!(style.semantic_text(text), text);
        assert_eq!(
            style.semantic_document(text),
            "\x1b[1mSummary · deploy · success\x1b[0m\n  host · ok\n  │ raw process output\n"
        );
    }

    #[test]
    fn no_color_capability_overrides_a_terminal() {
        let style = TerminalStyle::from_capabilities(true, true);
        assert_eq!(style.paint(Tone::Failure, "failure"), "failure");
        assert!(!style.enabled());
    }
}
