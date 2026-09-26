use std::process::Command;

use abird_host_agent::command::CommandSpec;

pub mod age;
pub mod disko;
pub mod nix;
pub mod nixos_generate_config;
pub mod nixos_install;
pub mod privilege;

pub(crate) const GIT_REPOSITORY_ENVIRONMENT: &[&str] = &[
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_DIR",
    "GIT_GRAFT_FILE",
    "GIT_IMPLICIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_NAMESPACE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_PREFIX",
    "GIT_SHALLOW_FILE",
    "GIT_WORK_TREE",
];

pub fn clear_git_repository_environment(command: &mut Command) {
    for variable in GIT_REPOSITORY_ENVIRONMENT {
        command.env_remove(variable);
    }
}

pub(crate) fn without_git_repository_environment(mut command: CommandSpec) -> CommandSpec {
    for variable in GIT_REPOSITORY_ENVIRONMENT {
        command = command.env_remove(variable);
    }
    command
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repository_commands_remove_every_git_checkout_selector() {
        let command = without_git_repository_environment(CommandSpec::new("/bin/true"));
        assert_eq!(command.removed_environment(), GIT_REPOSITORY_ENVIRONMENT);
    }
}
