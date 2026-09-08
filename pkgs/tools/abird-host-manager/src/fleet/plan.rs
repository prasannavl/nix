use serde::{Deserialize, Serialize};

use super::cli::Action;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Phase {
    TerraformDns,
    TerraformPlatform,
    Build,
    Snapshot,
    Deploy,
    Health,
    TerraformApps,
    DevelopmentBuild,
    BootstrapCheck,
    Clean,
    RepositorySync,
    DependencyCheck,
    Tofu,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkflowPlan {
    pub phases: Vec<Phase>,
}

impl WorkflowPlan {
    pub fn for_action(action: &Action) -> Self {
        let phases = match action {
            Action::Run => vec![
                Phase::TerraformDns,
                Phase::TerraformPlatform,
                Phase::Build,
                Phase::Snapshot,
                Phase::Deploy,
                Phase::Health,
                Phase::TerraformApps,
            ],
            Action::Deploy => vec![Phase::Build, Phase::Snapshot, Phase::Deploy, Phase::Health],
            Action::Build => vec![Phase::Build],
            Action::DevBuild => vec![Phase::DevelopmentBuild],
            Action::TerraformAll => vec![
                Phase::TerraformDns,
                Phase::TerraformPlatform,
                Phase::TerraformApps,
            ],
            Action::TerraformDns => vec![Phase::TerraformDns],
            Action::TerraformPlatform => vec![Phase::TerraformPlatform],
            Action::TerraformApps => vec![Phase::TerraformApps],
            Action::TerraformProject(_) => vec![Phase::Tofu],
            Action::CheckBootstrap => vec![Phase::BootstrapCheck],
            Action::Clean(_) => vec![Phase::Clean],
            Action::RepoSync => vec![Phase::RepositorySync],
            Action::Deps | Action::CheckDeps => vec![Phase::DependencyCheck],
            Action::Tofu(_) => vec![Phase::Tofu],
            Action::Help | Action::Version | Action::ListHosts | Action::ListGroups => Vec::new(),
        };
        Self { phases }
    }
}
