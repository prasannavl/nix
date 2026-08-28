use std::fmt::Write as _;

use serde_json::{Map, Value};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OutputContract {
    Structured,
    Stream,
    Passthrough,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PresentationKind {
    Inspect,
    Collection,
    Mutation,
    Fleet,
    Workflow,
    WorkflowCollection,
    Backup,
    BackupCollection,
    Job,
    JobCollection,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PresentationIntent {
    Inspect,
    Collection,
    Action,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandPresentation {
    pub heading: String,
    pub completed_heading: String,
    pub kind: PresentationKind,
    pub intent: PresentationIntent,
    pub contract: OutputContract,
    pub dry_run: bool,
}

impl CommandPresentation {
    pub fn structured(
        heading: impl Into<String>,
        completed_heading: impl Into<String>,
        kind: PresentationKind,
        dry_run: bool,
    ) -> Self {
        Self {
            heading: heading.into(),
            completed_heading: completed_heading.into(),
            kind,
            intent: PresentationIntent::Action,
            contract: OutputContract::Structured,
            dry_run,
        }
    }

    pub fn inspect(heading: impl Into<String>, kind: PresentationKind) -> Self {
        let heading = heading.into();
        Self {
            completed_heading: heading.clone(),
            heading,
            kind,
            intent: PresentationIntent::Inspect,
            contract: OutputContract::Structured,
            dry_run: false,
        }
    }

    pub fn collection(heading: impl Into<String>, kind: PresentationKind) -> Self {
        let heading = heading.into();
        Self {
            completed_heading: heading.clone(),
            heading,
            kind,
            intent: PresentationIntent::Collection,
            contract: OutputContract::Structured,
            dry_run: false,
        }
    }

    pub fn stream(heading: impl Into<String>) -> Self {
        let heading = heading.into();
        Self {
            completed_heading: heading.clone(),
            heading,
            kind: PresentationKind::Inspect,
            intent: PresentationIntent::Inspect,
            contract: OutputContract::Stream,
            dry_run: false,
        }
    }

    pub fn passthrough(heading: impl Into<String>) -> Self {
        let heading = heading.into();
        Self {
            completed_heading: heading.clone(),
            heading,
            kind: PresentationKind::Inspect,
            intent: PresentationIntent::Inspect,
            contract: OutputContract::Passthrough,
            dry_run: false,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Outcome {
    Planned,
    Succeeded,
    Accepted,
    Running,
    Deferred,
    AlreadySatisfied,
    Failed,
}

pub fn render(presentation: &CommandPresentation, value: &Value) -> String {
    match presentation.kind {
        PresentationKind::Workflow => render_workflow(presentation, value),
        PresentationKind::WorkflowCollection => render_workflow_list(presentation, value),
        PresentationKind::Backup | PresentationKind::BackupCollection => {
            render_backup(presentation, value)
        }
        PresentationKind::Job | PresentationKind::JobCollection => render_job(presentation, value),
        PresentationKind::Fleet => render_fleet(presentation, value),
        PresentationKind::Inspect | PresentationKind::Collection | PresentationKind::Mutation => {
            render_generic(presentation, value)
        }
    }
}

fn render_generic(presentation: &CommandPresentation, value: &Value) -> String {
    let mut output = String::new();
    render_heading(
        &mut output,
        presentation,
        presentation_outcome(presentation, value),
    );
    let mut body = String::new();
    render_value(&mut body, display_payload(value), 0, None, true);
    append_body(&mut output, &body);
    output
}

fn render_workflow(presentation: &CommandPresentation, value: &Value) -> String {
    let transaction = value
        .get("transaction")
        .filter(|transaction| transaction.is_object())
        .or_else(|| {
            (value.get("lifecycle_state").is_some()
                || (value.get("spec").is_some() && value.get("phase").is_some()))
            .then_some(value)
        });
    let Some(transaction) = transaction else {
        return render_generic(presentation, value);
    };

    let mut output = String::new();
    render_heading(
        &mut output,
        presentation,
        presentation_outcome(presentation, value),
    );
    let id = transaction
        .pointer("/spec/id")
        .and_then(Value::as_str)
        .unwrap_or("transaction");
    let items = transaction
        .pointer("/spec/items")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    let state = transaction
        .get("lifecycle_state")
        .and_then(Value::as_str)
        .or_else(|| transaction.get("phase").and_then(Value::as_str))
        .unwrap_or("unknown");

    writeln!(output, "ID      {id}").unwrap();
    writeln!(output, "State   {}", state_summary(state)).unwrap();
    if !items.is_empty() {
        let names = items.iter().filter_map(item_name).collect::<Vec<_>>();
        if !names.is_empty() {
            writeln!(output, "Items   {}", summarize_names(&names)).unwrap();
        }
        if let Some(route) = common_route(items) {
            writeln!(output, "Move    {route}").unwrap();
        }
    }

    let command = transaction
        .get("command_executions")
        .and_then(Value::as_array)
        .and_then(|commands| commands.last());
    if presentation.dry_run
        && let Some(steps) = command
            .and_then(|command| command.get("steps"))
            .and_then(Value::as_array)
    {
        output.push('\n');
        for step in steps {
            let description = step
                .get("description")
                .and_then(Value::as_str)
                .map(title)
                .unwrap_or_else(|| "Step".to_owned());
            match (
                step.get("status").and_then(Value::as_str),
                step.get("kind").and_then(Value::as_str),
            ) {
                (Some("succeeded"), _) => writeln!(output, "✓ {description}").unwrap(),
                (Some("failed"), _) => writeln!(output, "✗ {description}").unwrap(),
                (_, Some("verification" | "check")) => {
                    writeln!(output, "◇ {description} · deferred").unwrap()
                }
                _ => writeln!(output, "• Would {description}").unwrap(),
            }
        }
        output.push_str("\nReady to continue without --dry.\n");
    } else if let Some(next) =
        next_lifecycle_command(state, id, workflow_uses_local_authority(value, transaction))
    {
        writeln!(output, "Next    {next}").unwrap();
    }
    output
}

fn render_workflow_list(presentation: &CommandPresentation, value: &Value) -> String {
    let transactions = value.as_array().map(Vec::as_slice).unwrap_or_default();
    let mut output = String::new();
    render_heading(&mut output, presentation, Outcome::Succeeded);
    if transactions.is_empty() {
        output.push_str("None\n");
        return output;
    }
    for transaction in transactions {
        let id = transaction
            .pointer("/spec/id")
            .and_then(Value::as_str)
            .unwrap_or("transaction");
        let state = transaction
            .get("lifecycle_state")
            .and_then(Value::as_str)
            .or_else(|| transaction.get("phase").and_then(Value::as_str))
            .unwrap_or("unknown");
        let count = transaction
            .pointer("/spec/items")
            .and_then(Value::as_array)
            .map_or(0, Vec::len);
        writeln!(
            output,
            "{} {id} · {} · {count} item{}",
            status_marker(state),
            state_summary(state),
            if count == 1 { "" } else { "s" }
        )
        .unwrap();
    }
    output
}

fn render_backup(presentation: &CommandPresentation, value: &Value) -> String {
    if value.is_array() {
        return render_backup_list(presentation, value);
    }
    let backup = value
        .get("backup")
        .filter(|value| value.is_object())
        .unwrap_or(value);
    if backup.get("spec").is_none() {
        return render_generic(presentation, value);
    }

    let mut output = String::new();
    render_heading(
        &mut output,
        presentation,
        presentation_outcome(presentation, value),
    );
    let id = backup
        .pointer("/spec/id")
        .and_then(Value::as_str)
        .unwrap_or("backup");
    let phase = backup
        .get("phase")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    writeln!(output, "ID      {id}").unwrap();
    writeln!(output, "State   {}", human_token(phase)).unwrap();

    let copies = backup
        .get("copies")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    if !copies.is_empty() {
        let completed = copies
            .iter()
            .filter(|copy| copy.get("status").and_then(Value::as_str) == Some("complete"))
            .count();
        let failed = copies
            .iter()
            .filter(|copy| copy.get("status").and_then(Value::as_str) == Some("failed"))
            .count();
        write!(output, "Copies  {completed}/{} complete", copies.len()).unwrap();
        if failed != 0 {
            write!(output, " · {failed} failed").unwrap();
        }
        output.push('\n');
        output.push('\n');
        for copy in copies {
            let item = copy.get("item").and_then(Value::as_str).unwrap_or("item");
            let status = copy
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let destination = copy
                .get("destination")
                .map(destination_summary)
                .unwrap_or_else(|| "destination".to_owned());
            writeln!(
                output,
                "{} {item} → {destination} · {}",
                status_marker(status),
                human_token(status)
            )
            .unwrap();
        }
    }
    if let Some(restore) = backup.get("restore").filter(|value| value.is_object())
        && let Some(phase) = restore.get("phase").and_then(Value::as_str)
    {
        writeln!(output, "Restore {}", human_token(phase)).unwrap();
    }
    output
}

fn render_backup_list(presentation: &CommandPresentation, value: &Value) -> String {
    let mut output = String::new();
    render_heading(&mut output, presentation, Outcome::Succeeded);
    let backups = value.as_array().map(Vec::as_slice).unwrap_or_default();
    if backups.is_empty() {
        output.push_str("None\n");
        return output;
    }
    for backup in backups {
        let id = backup
            .pointer("/spec/id")
            .and_then(Value::as_str)
            .unwrap_or("backup");
        let phase = backup
            .get("phase")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        writeln!(
            output,
            "{} {id} · {}",
            status_marker(phase),
            human_token(phase)
        )
        .unwrap();
    }
    output
}

fn render_job(presentation: &CommandPresentation, value: &Value) -> String {
    if value.is_array() || value.pointer("/result/jobs").is_some() {
        return render_job_list(presentation, value);
    }
    let job = value
        .pointer("/result/job/job")
        .filter(|value| value.is_object())
        .or_else(|| {
            value
                .pointer("/result/job")
                .filter(|value| value.is_object())
        })
        .or_else(|| value.get("job").filter(|value| value.is_object()))
        .or_else(|| {
            value
                .get("result")
                .filter(|result| result.get("spec").is_some() && result.get("status").is_some())
        })
        .unwrap_or(value);
    if job.get("spec").is_none() || job.get("status").is_none() {
        return render_generic(presentation, value);
    }
    let mut output = String::new();
    render_heading(
        &mut output,
        presentation,
        presentation_outcome(presentation, value),
    );
    let id = job
        .pointer("/spec/job_id")
        .and_then(Value::as_str)
        .or_else(|| job.pointer("/spec/id").and_then(Value::as_str))
        .unwrap_or("job");
    let status = job
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    writeln!(output, "ID       {id}").unwrap();
    writeln!(output, "Status   {}", human_token(status)).unwrap();
    if let Some(attempts) = job.get("attempts").and_then(Value::as_u64) {
        writeln!(output, "Attempts {attempts}").unwrap();
    }
    if let Some(error) = job.get("error").and_then(Value::as_str) {
        writeln!(output, "Error    {error}").unwrap();
    }
    if let Some(progress) = job.get("progress").filter(|value| !value.is_null()) {
        writeln!(output, "Progress {}", compact_value(progress)).unwrap();
    }
    output
}

fn render_job_list(presentation: &CommandPresentation, value: &Value) -> String {
    let mut output = String::new();
    render_heading(&mut output, presentation, Outcome::Succeeded);
    let jobs = value
        .as_array()
        .map(Vec::as_slice)
        .or_else(|| {
            value
                .pointer("/result/jobs")
                .and_then(Value::as_array)
                .map(Vec::as_slice)
        })
        .unwrap_or_default();
    if jobs.is_empty() {
        output.push_str("None\n");
        return output;
    }
    for job in jobs {
        let id = job
            .pointer("/spec/job_id")
            .and_then(Value::as_str)
            .unwrap_or("job");
        let status = job
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        writeln!(
            output,
            "{} {id} · {}",
            status_marker(status),
            human_token(status)
        )
        .unwrap();
    }
    output
}

fn render_fleet(presentation: &CommandPresentation, value: &Value) -> String {
    let mut output = String::new();
    render_heading(
        &mut output,
        presentation,
        presentation_outcome(presentation, value),
    );
    if presentation.dry_run {
        let mut body = String::new();
        render_value(&mut body, value, 0, None, true);
        append_body(&mut output, &body);
        return output;
    }
    let results = value
        .get("results")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    if results.is_empty() {
        output.push_str("No hosts selected.\n");
        return output;
    }
    for result in results {
        let host = result.get("host").and_then(Value::as_str).unwrap_or("host");
        if result.get("ok").and_then(Value::as_bool) == Some(true) {
            writeln!(output, "✓ {host}").unwrap();
        } else {
            let error = result
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("operation failed");
            writeln!(output, "✗ {host} · {error}").unwrap();
        }
    }
    output
}

fn render_heading(output: &mut String, presentation: &CommandPresentation, outcome: Outcome) {
    match outcome {
        Outcome::Planned => {
            writeln!(output, "Dry run · {}", presentation.heading).unwrap();
            output.push_str("No changes will be made.\n\n");
        }
        Outcome::Succeeded
            if matches!(
                presentation.intent,
                PresentationIntent::Inspect | PresentationIntent::Collection
            ) =>
        {
            writeln!(output, "{}\n", presentation.heading).unwrap();
        }
        Outcome::Succeeded => writeln!(output, "✓ {}\n", presentation.completed_heading).unwrap(),
        Outcome::Accepted => writeln!(output, "● {} accepted\n", presentation.heading).unwrap(),
        Outcome::Running => writeln!(output, "● {} in progress\n", presentation.heading).unwrap(),
        Outcome::Deferred => {
            writeln!(output, "◇ {} · runtime deferred\n", presentation.heading).unwrap()
        }
        Outcome::AlreadySatisfied => writeln!(
            output,
            "✓ {} · already satisfied\n",
            presentation.completed_heading
        )
        .unwrap(),
        Outcome::Failed => writeln!(output, "✗ {}\n", presentation.heading).unwrap(),
    }
}

fn outcome(value: &Value, dry_run: bool) -> Outcome {
    if dry_run || value.get("dry_run").and_then(Value::as_bool) == Some(true) {
        return Outcome::Planned;
    }
    if value.get("ok").and_then(Value::as_bool) == Some(false) {
        return Outcome::Failed;
    }
    let status = value
        .get("status")
        .and_then(Value::as_str)
        .or_else(|| value.pointer("/job/status").and_then(Value::as_str))
        .or_else(|| value.pointer("/result/job/status").and_then(Value::as_str))
        .or_else(|| {
            value
                .pointer("/result/job/job/status")
                .and_then(Value::as_str)
        })
        .or_else(|| {
            value
                .pointer("/transaction/command_executions")
                .and_then(Value::as_array)
                .and_then(|commands| commands.last())
                .and_then(|command| command.get("status"))
                .and_then(Value::as_str)
        })
        .or_else(|| {
            value
                .get("command_executions")
                .and_then(Value::as_array)
                .and_then(|commands| commands.last())
                .and_then(|command| command.get("status"))
                .and_then(Value::as_str)
        });
    match status {
        Some("failed" | "blocked") => Outcome::Failed,
        _ if value.get("runtime").and_then(Value::as_str) == Some("skipped") => Outcome::Deferred,
        Some("pending" | "accepted") => Outcome::Accepted,
        Some("running" | "in_progress") => Outcome::Running,
        _ if value.get("changed").and_then(Value::as_bool) == Some(false) => {
            Outcome::AlreadySatisfied
        }
        _ => Outcome::Succeeded,
    }
}

fn presentation_outcome(presentation: &CommandPresentation, value: &Value) -> Outcome {
    match presentation.intent {
        PresentationIntent::Inspect | PresentationIntent::Collection => Outcome::Succeeded,
        PresentationIntent::Action => outcome(value, presentation.dry_run),
    }
}

fn display_payload(value: &Value) -> &Value {
    let Some(fields) = value.as_object() else {
        return value;
    };
    let Some(result) = fields.get("result") else {
        return value;
    };
    if fields.keys().all(|name| {
        matches!(
            name.as_str(),
            "ok" | "human" | "operation" | "result" | "status"
        )
    }) {
        result
    } else {
        value
    }
}

fn render_value(
    output: &mut String,
    value: &Value,
    indent: usize,
    label: Option<&str>,
    skip_control_fields: bool,
) {
    let prefix = " ".repeat(indent);
    match value {
        Value::Object(fields) => {
            if let Some(label) = label {
                writeln!(output, "{prefix}{}", title(label)).unwrap();
            }
            render_object(
                output,
                fields,
                indent + usize::from(label.is_some()) * 2,
                skip_control_fields,
            );
        }
        Value::Array(values) => {
            if let Some(label) = label {
                writeln!(output, "{prefix}{}", title(label)).unwrap();
            }
            render_array(
                output,
                values,
                indent + usize::from(label.is_some()) * 2,
                skip_control_fields,
            );
        }
        Value::Null => {
            if let Some(label) = label {
                writeln!(output, "{prefix}{:<12} none", title(label)).unwrap();
            }
        }
        _ => {
            let rendered = compact_value(value);
            if let Some(label) = label {
                writeln!(output, "{prefix}{:<12} {rendered}", title(label)).unwrap();
            } else {
                writeln!(output, "{prefix}{rendered}").unwrap();
            }
        }
    }
}

fn render_object(
    output: &mut String,
    fields: &Map<String, Value>,
    indent: usize,
    skip_control_fields: bool,
) {
    let fields = ordered_fields(fields)
        .into_iter()
        .filter(|(name, value)| {
            !(value.is_null()
                || skip_control_fields
                    && matches!(
                        name.as_str(),
                        "ok" | "dry_run"
                            | "operation"
                            | "executable"
                            | "arguments"
                            | "stdout"
                            | "stderr"
                    ))
        })
        .collect::<Vec<_>>();
    let scalar_width = fields
        .iter()
        .filter(|(_, value)| is_compact(value))
        .map(|(name, _)| title(name).chars().count())
        .max()
        .unwrap_or(0)
        .min(24);
    for (name, value) in fields.iter().filter(|(_, value)| is_compact(value)) {
        writeln!(
            output,
            "{}{:<width$} {}",
            " ".repeat(indent),
            title(name),
            compact_value(value),
            width = scalar_width
        )
        .unwrap();
    }
    let nested = fields
        .iter()
        .filter(|(_, value)| !is_compact(value))
        .collect::<Vec<_>>();
    if scalar_width != 0 && !nested.is_empty() {
        output.push('\n');
    }
    for (index, (name, value)) in nested.iter().enumerate() {
        render_value(output, value, indent, Some(name), skip_control_fields);
        if index + 1 < nested.len() {
            output.push('\n');
        }
    }
}

fn render_array(output: &mut String, values: &[Value], indent: usize, skip_control_fields: bool) {
    let prefix = " ".repeat(indent);
    if values.is_empty() {
        writeln!(output, "{prefix}None").unwrap();
        return;
    }
    for value in values {
        match value {
            Value::Object(fields) => {
                if let Some(state) = service_result_state(fields) {
                    writeln!(output, "{prefix}• State {}", human_token(state)).unwrap();
                    let remaining: Map<String, Value> = fields
                        .iter()
                        .filter(|(name, _)| {
                            !matches!(
                                name.as_str(),
                                "success" | "stdout" | "stderr" | "executable" | "arguments"
                            )
                        })
                        .map(|(name, value)| (name.clone(), value.clone()))
                        .collect();
                    if !remaining.is_empty() {
                        render_object(output, &remaining, indent + 2, skip_control_fields);
                    }
                } else if let Some((identity_name, identity)) = identity(fields) {
                    write!(output, "{prefix}• {identity}").unwrap();
                    let descriptors = ["status", "state", "phase", "address", "user", "resource"]
                        .into_iter()
                        .filter(|name| *name != identity_name)
                        .filter_map(|name| {
                            fields
                                .get(name)
                                .filter(|value| is_compact(value))
                                .map(compact_value)
                        })
                        .collect::<Vec<_>>();
                    if !descriptors.is_empty() {
                        write!(output, " · {}", descriptors.join(" · ")).unwrap();
                    }
                    output.push('\n');
                    let remaining: Map<String, Value> = fields
                        .iter()
                        .filter(|(name, _)| {
                            name.as_str() != identity_name
                                && !matches!(
                                    name.as_str(),
                                    "status" | "state" | "phase" | "address" | "user" | "resource"
                                )
                        })
                        .map(|(name, value)| (name.clone(), value.clone()))
                        .collect();
                    if !remaining.is_empty() {
                        render_object(output, &remaining, indent + 2, skip_control_fields);
                    }
                } else {
                    writeln!(output, "{prefix}•").unwrap();
                    render_object(output, fields, indent + 2, skip_control_fields);
                }
            }
            _ => writeln!(output, "{prefix}• {}", compact_value(value)).unwrap(),
        }
    }
}

fn service_result_state(fields: &Map<String, Value>) -> Option<&str> {
    fields.get("success")?.as_bool()?;
    fields.get("target")?.as_object()?;
    fields
        .get("stdout")?
        .as_str()
        .map(str::trim)
        .filter(|state| {
            matches!(
                *state,
                "active" | "inactive" | "failed" | "activating" | "deactivating" | "reloading"
            )
        })
}

fn append_body(output: &mut String, body: &str) {
    if body.trim().is_empty() {
        return;
    }
    output.push_str(body.trim_end());
    output.push('\n');
}

fn ordered_fields(fields: &Map<String, Value>) -> Vec<(&String, &Value)> {
    let mut fields = fields.iter().collect::<Vec<_>>();
    fields.sort_by_key(|(name, _)| field_priority(name));
    fields
}

fn field_priority(name: &str) -> (usize, &str) {
    let priority = match name {
        "name" | "id" | "job_id" | "wipe_id" => 0,
        "status" | "state" | "phase" | "ok" => 1,
        "host" | "service" | "resource" | "unit" => 2,
        "source" | "target" | "from" | "to" => 3,
        "address" | "user" | "groups" => 4,
        "error" | "failure" => 100,
        _ => 50,
    };
    (priority, name)
}

fn identity(fields: &Map<String, Value>) -> Option<(&str, String)> {
    ["name", "id", "job_id", "host", "service", "resource"]
        .into_iter()
        .find_map(|name| {
            fields
                .get(name)
                .filter(|value| is_compact(value))
                .map(|value| (name, compact_value(value)))
        })
}

fn is_compact(value: &Value) -> bool {
    matches!(
        value,
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_)
    ) || value.as_array().is_some_and(|values| {
        values
            .iter()
            .all(|value| !value.is_object() && !value.is_array())
    })
}

fn compact_value(value: &Value) -> String {
    match value {
        Value::Null => "none".to_owned(),
        Value::Bool(value) => if *value { "yes" } else { "no" }.to_owned(),
        Value::Number(value) => value.to_string(),
        Value::String(value) => value.clone(),
        Value::Array(values) if values.iter().all(is_compact) => {
            if values.is_empty() {
                "none".to_owned()
            } else {
                values
                    .iter()
                    .map(compact_value)
                    .collect::<Vec<_>>()
                    .join(", ")
            }
        }
        Value::Object(fields) => {
            if let Some((_, identity)) = identity(fields) {
                identity
            } else {
                serde_json::to_string(value).unwrap_or_else(|_| "details unavailable".to_owned())
            }
        }
        _ => serde_json::to_string(value).unwrap_or_else(|_| "details unavailable".to_owned()),
    }
}

fn destination_summary(destination: &Value) -> String {
    destination
        .pointer("/endpoint/host")
        .and_then(Value::as_str)
        .or_else(|| destination.get("host").and_then(Value::as_str))
        .or_else(|| destination.get("path").and_then(Value::as_str))
        .map(str::to_owned)
        .unwrap_or_else(|| compact_value(destination))
}

fn item_name(item: &Value) -> Option<&str> {
    ["service", "resource", "instance", "id"]
        .into_iter()
        .find_map(|field| item.get(field).and_then(Value::as_str))
}

fn summarize_names(names: &[&str]) -> String {
    const VISIBLE: usize = 3;
    if names.len() <= VISIBLE {
        names.join(", ")
    } else {
        format!(
            "{} · +{} more",
            names[..VISIBLE].join(", "),
            names.len() - VISIBLE
        )
    }
}

fn common_route(items: &[Value]) -> Option<String> {
    let routes = items
        .iter()
        .filter_map(|item| {
            let source = item
                .pointer("/source/host")
                .and_then(Value::as_str)
                .or_else(|| item.pointer("/source/controller").and_then(Value::as_str))?;
            let target = item
                .pointer("/target/host")
                .and_then(Value::as_str)
                .or_else(|| item.pointer("/target/controller").and_then(Value::as_str))?;
            Some((source, target))
        })
        .collect::<Vec<_>>();
    let first = routes.first()?;
    routes
        .iter()
        .all(|route| route == first)
        .then(|| format!("{} → {}", first.0, first.1))
}

fn workflow_uses_local_authority(value: &Value, transaction: &Value) -> bool {
    value.pointer("/repository/pushed").and_then(Value::as_bool) == Some(false)
        || transaction
            .get("command_executions")
            .and_then(Value::as_array)
            .is_some_and(|commands| {
                commands.iter().any(|command| {
                    command
                        .get("steps")
                        .and_then(Value::as_array)
                        .is_some_and(|steps| {
                            steps.iter().any(|step| {
                                step.get("id")
                                    .and_then(Value::as_str)
                                    .is_some_and(|id| id.contains("retain-local"))
                            })
                        })
                })
            })
}

fn next_lifecycle_command(state: &str, id: &str, local: bool) -> Option<String> {
    let command = match state {
        "moved" | "seeded" => "prepare",
        "prepared" => "run",
        "target_active" | "running" | "closing_complete" | "closing_rollback" | "rolled_back" => {
            "close"
        }
        _ => return None,
    };
    let authority = if local { " --local" } else { "" };
    Some(format!(
        "abird-host-manager{authority} transaction {command} {id}"
    ))
}

fn state_summary(state: &str) -> &str {
    match state {
        "source_active" | "planned" => "source active",
        "moved" | "seeded" => "source active · target held · warm seed verified",
        "preparing" => "both sides held · synchronizing data",
        "prepared" | "verified" => "both sides held · data synchronized and verified",
        "running" => "source held · activating and verifying target",
        "target_active" | "cutover" => "target active · traffic on target · source held",
        "closing_complete" => "completing on target · inactive hold retained",
        "closing_rollback" => "rolling back to source · inactive hold retained",
        "rolled_back" => "source active · target held · rollback complete; close pending",
        "closed_on_target" => "target canonical · migration closed",
        "closed_on_source" | "closed" => "source canonical · migration closed",
        _ => state,
    }
}

fn status_marker(status: &str) -> &'static str {
    match status {
        "complete" | "completed" | "succeeded" | "activated" | "closed" => "✓",
        "failed" | "aborted" | "blocked" => "✗",
        "pending" | "running" | "restoring" | "deleting" => "●",
        _ => "•",
    }
}

fn human_token(value: &str) -> String {
    value.replace(['_', '-'], " ")
}

fn title(value: &str) -> String {
    let value = human_token(value);
    let mut characters = value.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn renders_dry_mutation_without_success_language() {
        let output = render(
            &CommandPresentation::structured(
                "Restart service zulip",
                "Restarted service zulip",
                PresentationKind::Mutation,
                true,
            ),
            &json!({
                "dry_run": true,
                "host": "target",
                "resource": "service:abird-zulip",
            }),
        );
        assert_eq!(
            output,
            "Dry run · Restart service zulip\nNo changes will be made.\n\nHost     target\nResource service:abird-zulip\n"
        );
        assert!(!output.contains('✓'));
    }

    #[test]
    fn backup_record_never_uses_the_transaction_view() {
        let output = render(
            &CommandPresentation::structured(
                "Backup backup-1",
                "Created backup backup-1",
                PresentationKind::Backup,
                false,
            ),
            &json!({
                "schema_version": 1,
                "spec": {"id": "backup-1"},
                "phase": "complete",
                "copies": [{
                    "item": "item-001",
                    "destination": {
                        "kind": "host",
                        "endpoint": {"host": "backup-host", "instance": null}
                    },
                    "status": "complete"
                }]
            }),
        );
        assert!(output.starts_with("✓ Created backup backup-1\n"));
        assert!(output.contains("ID      backup-1"));
        assert!(output.contains("Copies  1/1 complete"));
        assert!(output.contains("item-001 → backup-host"));
        assert!(!output.contains("Next"));
    }

    #[test]
    fn inspections_report_state_without_claiming_an_operation_succeeded() {
        let output = render(
            &CommandPresentation::inspect("Backup backup-1", PresentationKind::Backup),
            &json!({
                "spec": {"id": "backup-1"},
                "phase": "complete",
                "copies": []
            }),
        );
        assert!(output.starts_with("Backup backup-1\n\n"));
        assert!(!output.contains('✓'));

        let output = render(
            &CommandPresentation::inspect("Job job-1 · target", PresentationKind::Job),
            &json!({
                "ok": true,
                "result": {
                    "spec": {"job_id": "job-1"},
                    "status": "pending",
                    "attempts": 1
                }
            }),
        );
        assert!(output.starts_with("Job job-1 · target\n\n"));
        assert!(output.contains("Status   pending"));
        assert!(!output.starts_with('●'));
    }

    #[test]
    fn generic_views_strip_the_agent_transport_envelope() {
        let output = render(
            &CommandPresentation::inspect("Service mail", PresentationKind::Inspect),
            &json!({
                "ok": true,
                "operation": "resource_status",
                "human": "resource status",
                "result": {
                    "services": [{
                        "success": true,
                        "target": {
                            "scope": "system",
                            "unit": "mail.service"
                        },
                        "executable": "/run/current-system/sw/bin/systemctl",
                        "arguments": ["is-active", "mail.service"],
                        "stdout": "active",
                        "stderr": ""
                    }]
                }
            }),
        );
        assert!(output.starts_with("Service mail\n\nServices\n"));
        assert!(!output.contains("Operation"));
        assert!(!output.contains("Human"));
        assert!(!output.contains("Result"));
        assert!(!output.contains("Executable"));
        assert!(!output.contains("Arguments"));
        assert!(!output.contains("Stdout"));
        assert!(output.contains("• State active"));
        assert!(output.contains("Unit  mail.service"));
    }

    #[test]
    fn workflow_summary_covers_multiple_items() {
        let output = render(
            &CommandPresentation::structured(
                "Move services",
                "Moved services",
                PresentationKind::Workflow,
                false,
            ),
            &json!({
                "spec": {
                    "id": "move-mail",
                    "items": [
                        {"service": "smtp", "source": {"host": "a"}, "target": {"host": "b"}},
                        {"service": "imap", "source": {"host": "a"}, "target": {"host": "b"}}
                    ]
                },
                "lifecycle_state": "moved"
            }),
        );
        assert!(output.contains("Items   smtp, imap"));
        assert!(output.contains("Move    a → b"));
        assert!(output.contains("transaction prepare move-mail"));
    }

    #[test]
    fn workflow_next_command_preserves_local_authority() {
        let output = render(
            &CommandPresentation::structured(
                "Move service zulip",
                "Initialized migration for service zulip",
                PresentationKind::Workflow,
                false,
            ),
            &json!({
                "repository": {"pushed": false},
                "transaction": {
                    "spec": {"id": "move-local", "items": []},
                    "lifecycle_state": "moved",
                    "command_executions": []
                }
            }),
        );
        assert!(
            output.contains("Next    abird-host-manager --local transaction prepare move-local")
        );
        assert!(!output.contains("✓ Moved service zulip"));
    }

    #[test]
    fn legacy_workflow_without_lifecycle_state_keeps_the_workflow_view() {
        let output = render(
            &CommandPresentation::inspect("Transaction move-legacy", PresentationKind::Workflow),
            &json!({
                "spec": {"id": "move-legacy", "items": []},
                "phase": "prepared",
                "command_executions": []
            }),
        );
        assert!(output.starts_with("Transaction move-legacy\n\n"));
        assert!(output.contains("ID      move-legacy"));
        assert!(output.contains("State   both sides held"));
    }

    #[test]
    fn skipped_workflow_runtime_is_deferred_not_complete() {
        let presentation = CommandPresentation::structured(
            "Move service zulip",
            "Moved service zulip",
            PresentationKind::Workflow,
            false,
        );
        let rendered = render(
            &presentation,
            &json!({
                "runtime": "skipped",
                "transaction": {
                    "spec": {"id": "move-1", "items": []},
                    "lifecycle_state": "published",
                    "command_executions": [{"status": "running"}]
                }
            }),
        );
        assert!(rendered.starts_with("◇ Move service zulip · runtime deferred"));
        assert!(!rendered.contains("✓ Moved service zulip"));
    }

    #[test]
    fn skipped_runtime_is_deferred_for_non_workflow_actions() {
        let presentation = CommandPresentation::structured(
            "Set hold for zulip",
            "Set hold for zulip",
            PresentationKind::Mutation,
            false,
        );
        let rendered = render(
            &presentation,
            &json!({"runtime": "skipped", "repository": {"published": true}}),
        );
        assert!(rendered.starts_with("◇ Set hold for zulip · runtime deferred"));
        assert!(!rendered.starts_with('✓'));
    }

    #[test]
    fn fleet_failure_is_one_coherent_summary() {
        let output = render(
            &CommandPresentation::structured(
                "Clean hosts",
                "Cleaned hosts",
                PresentationKind::Fleet,
                false,
            ),
            &json!({
                "ok": false,
                "results": [
                    {"host": "a", "ok": true, "result": {}},
                    {"host": "b", "ok": false, "error": "held"}
                ]
            }),
        );
        assert_eq!(output, "✗ Clean hosts\n\n✓ a\n✗ b · held\n");
    }
}
