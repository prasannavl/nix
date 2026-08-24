# `pvl-a1` Desktop Media Apps

## Package ownership

`hosts/common/pvl.nix` installs imv, `vimiv-qt`, Lollypop, Amberol, and
Recordbox for every Pvl host. `hosts/pvl-a1/packages.nix` deliberately repeats
imv and also installs Euphonica. ChatGPT comes from the root `llm-agents` input
as `inputs.llm-agents.packages.${system}.chatgpt`; the locked package evaluated
and built as version `26.818.31338` during validation.

The MIME-associated packages are intentionally shared through the common host
module. Euphonica and ChatGPT remain scoped to `pvl-a1`. The MIME policy in
`users/pvl/mime-apps/default.nix` is unconditional for the `pvl` user on every
host.

## MIME policy

- Common image types default to Loupe and associate Loupe, imv, and vimiv.
- Common audio types default to MPV and associate MPV, VLC, Lollypop, Amberol,
  and Recordbox.
- Common video types default to MPV and associate MPV and VLC.

Euphonica is installed as a music-library application but is not registered as
an audio file handler. Its upstream desktop entry declares neither MIME types
nor a file or URL placeholder in `Exec`, so an Open-With association would
launch Euphonica without passing the selected file.

## Validation

- Alejandra formatting and `git diff --check` pass.
- Both the `pvl-a1` and `pvl-l5` Home Manager evaluations contain the same
  unconditional `pvl` MIME associations.
- The requested package derivations build from the effective host
  configurations.
