{switch-to-configuration-ng, ...}:
switch-to-configuration-ng.overrideAttrs (old: {
  patches = (old.patches or []) ++ [./skip-greeter-sessions.patch];
})
