use std::env;
use std::io::{self, IsTerminal};

const RESET: &str = "\x1b[0m";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Tone {
    Success,
    Failure,
    FailureDetail,
    Warning,
    Active,
    Label,
    Emphasis,
    Muted,
}

impl Tone {
    fn code(self) -> &'static str {
        match self {
            Self::Success => "\x1b[1;32m",
            Self::Failure => "\x1b[1;31m",
            Self::FailureDetail => "\x1b[31m",
            Self::Warning => "\x1b[1;33m",
            Self::Active => "\x1b[1;36m",
            Self::Label => "\x1b[1;34m",
            Self::Emphasis => "\x1b[1m",
            Self::Muted => "\x1b[2m",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TerminalStyle {
    enabled: bool,
}

impl TerminalStyle {
    pub fn for_stdout() -> Self {
        Self::from_capabilities(io::stdout().is_terminal(), color_disabled_by_environment())
    }

    pub fn for_stderr() -> Self {
        Self::from_capabilities(io::stderr().is_terminal(), color_disabled_by_environment())
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

    pub fn semantic_document(self, document: &str) -> String {
        let mut output = String::with_capacity(document.len());
        let mut first_nonempty = true;
        for segment in document.split_inclusive('\n') {
            let (line, newline) = segment
                .strip_suffix('\n')
                .map_or((segment, ""), |line| (line, "\n"));
            output.push_str(&self.semantic_line(line, first_nonempty));
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
        || env::var_os("TERM")
            .is_some_and(|term| term.to_string_lossy().eq_ignore_ascii_case("dumb"))
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
        assert!(document.contains("\x1b[1;32m✓ Complete\x1b[0m"));
        assert!(document.contains("\x1b[1;31m✗ Failed\x1b[0m"));
        assert!(document.contains("\x1b[1;36m● Running\x1b[0m"));
        assert!(document.contains("\x1b[1;33m◇ Deferred\x1b[0m"));
        assert!(document.contains("\x1b[1;34mState\x1b[0m   target active"));
    }

    #[test]
    fn no_color_capability_overrides_a_terminal() {
        let style = TerminalStyle::from_capabilities(true, true);
        assert_eq!(style.paint(Tone::Failure, "failure"), "failure");
        assert!(!style.enabled());
    }
}
