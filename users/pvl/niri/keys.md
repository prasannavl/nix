# Niri Key Map

Assumes local `config.kdl` includes `base-config.kdl` then `nix-config.kdl`,
with no extra local overrides.

## Launch And Session

- `Mod+Shift+Slash`: show hotkey overlay
- `Mod+T`: open Alacritty
- `Mod+D`: open Noctalia launcher, fallback fuzzel
- `Super+Alt+L`: lock with swaylock
- `Super+Alt+S`: toggle Orca
- `Mod+Escape`: toggle shortcut inhibitor
- `Mod+Shift+E`: quit Niri
- `Ctrl+Alt+Delete`: quit Niri
- `Mod+Shift+P`: power off monitors

## Directional Focus And Movement

### Left: `H` / `Left`

- `Mod+H`, `Mod+Left`: focus column left
- `Mod+Ctrl+H`, `Mod+Ctrl+Left`: move column left
- `Mod+Shift+H`, `Mod+Shift+Left`: focus monitor left
- `Mod+Ctrl+Shift+H`, `Mod+Ctrl+Shift+Left`: move column to monitor left

### Down: `J` / `Down`

- `Mod+J`, `Mod+Down`: focus window down
- `Mod+Ctrl+J`, `Mod+Ctrl+Down`: move window down
- `Mod+Shift+J`, `Mod+Shift+Down`: focus monitor down
- `Mod+Ctrl+Shift+J`, `Mod+Ctrl+Shift+Down`: move column to monitor down

### Up: `K` / `Up`

- `Mod+K`, `Mod+Up`: focus window up
- `Mod+Ctrl+K`, `Mod+Ctrl+Up`: move window up
- `Mod+Shift+K`, `Mod+Shift+Up`: focus monitor up
- `Mod+Ctrl+Shift+K`, `Mod+Ctrl+Shift+Up`: move column to monitor up

### Right: `L` / `Right`

- `Mod+L`, `Mod+Right`: focus column right
- `Mod+Ctrl+L`, `Mod+Ctrl+Right`: move column right
- `Mod+Shift+L`, `Mod+Shift+Right`: focus monitor right
- `Mod+Ctrl+Shift+L`, `Mod+Ctrl+Shift+Right`: move column to monitor right

### First / Last Column

- `Mod+Home`: focus first column
- `Mod+Ctrl+Home`: move column to first
- `Mod+End`: focus last column
- `Mod+Ctrl+End`: move column to last

## Workspaces

### Up / Down Workspace

- `Mod+Page_Down`, `Mod+U`: focus workspace down
- `Mod+Ctrl+Page_Down`, `Mod+Ctrl+U`: move column to workspace down
- `Mod+Shift+Page_Down`, `Mod+Shift+U`: move workspace down
- `Mod+Page_Up`, `Mod+I`: focus workspace up
- `Mod+Ctrl+Page_Up`, `Mod+Ctrl+I`: move column to workspace up
- `Mod+Shift+Page_Up`, `Mod+Shift+I`: move workspace up

### Numbered Workspaces

- `Mod+1` ... `Mod+9`: focus workspace 1 ... 9
- `Mod+Ctrl+1` ... `Mod+Ctrl+9`: move column to workspace 1 ... 9

## Mouse Wheel With `Mod`

- `Mod+WheelScrollDown`: focus workspace down
- `Mod+Ctrl+WheelScrollDown`: move column to workspace down
- `Mod+Shift+WheelScrollDown`: focus column right
- `Mod+Ctrl+Shift+WheelScrollDown`: move column right
- `Mod+WheelScrollUp`: focus workspace up
- `Mod+Ctrl+WheelScrollUp`: move column to workspace up
- `Mod+Shift+WheelScrollUp`: focus column left
- `Mod+Ctrl+Shift+WheelScrollUp`: move column left
- `Mod+WheelScrollRight`: focus column right
- `Mod+Ctrl+WheelScrollRight`: move column right
- `Mod+WheelScrollLeft`: focus column left
- `Mod+Ctrl+WheelScrollLeft`: move column left

## Window And Column Layout

- `Mod+Q`: close window
- `Mod+BracketLeft`: consume or expel window left
- `Mod+BracketRight`: consume or expel window right
- `Mod+Comma`: consume window into column
- `Mod+Period`: expel window from column
- `Mod+F`: maximize column
- `Mod+Ctrl+F`: expand column to available width
- `Mod+Shift+F`: fullscreen window
- `Mod+R`: switch preset column width
- `Mod+Ctrl+R`: reset window height
- `Mod+Shift+R`: switch preset window height
- `Mod+Minus`: shrink column width
- `Mod+Shift+Minus`: shrink window height
- `Mod+Equal`: grow column width
- `Mod+Shift+Equal`: grow window height
- `Mod+V`: toggle floating
- `Mod+Shift+V`: switch focus between floating and tiling
- `Mod+W`: toggle tabbed column display
- `Mod+O`: toggle overview
- `Mod+C`: center column
- `Mod+Ctrl+C`: center visible columns

## Dynamic Screencast Target

- `Mod+Shift+W`: set target to focused window
- `Mod+Shift+M`: set target to focused monitor
- `Mod+Shift+C`: clear target

## Screenshots

- `Print`: interactive screenshot
- `Ctrl+Print`: screenshot screen to clipboard only
- `Alt+Print`: screenshot window to clipboard only

## Audio, Media, Brightness

- `XF86AudioRaiseVolume`: volume up
- `XF86AudioLowerVolume`: volume down
- `XF86AudioMute`: mute output
- `XF86AudioMicMute`: mute microphone
- `XF86AudioPlay`: play/pause
- `XF86AudioStop`: stop media
- `XF86AudioPrev`: previous media
- `XF86AudioNext`: next media
- `XF86MonBrightnessUp`: brightness up
- `XF86MonBrightnessDown`: brightness down

## Mod Key Occupancy

Legend:

- `m`: `Mod+Key`
- `c`: `Mod+Ctrl+Key`
- `s`: `Mod+Shift+Key`
- `cs`: `Mod+Ctrl+Shift+Key`
- `-`: unused with `Mod`

```text
| Esc      |          | Print    | C+Prt    | A+Prt    |          | C+A+Del  | S+A+L    | S+A+S    
  m                     shot       clip       clip                  quit       lock       orca

| `        | 1        | 2        | 3        | 4        | 5        | 6        | 7        | 8        | 9        | 0        | -        | =        | Backspace 
  -          m,c        m,c        m,c        m,c        m,c        m,c        m,c        m,c        m,c        -          m,s        m,s        -

| Tab  | Q        | W        | E        | R        | T        | Y        | U        | I        | O        | P        | [        | ]        | \        
  -      m          m,s        s          m,c,s      m          -          m,c,s      m,c,s      m          s          m          m          -

| Caps | A        | S        | D        | F        | G        | H        | J        | K        | L        | ;        | '        | Enter 
  -      -          -          m          m,c,s      -          m,c,s,cs   m,c,s,cs   m,c,s,cs   m,c,s,cs   -          -          -

| Shift | Z        | X        | C        | V        | B        | N        | M        | ,        | .        | /        | Shift 
  -       -          -          m,c,s      m,s        -          -          s          m          m          s          -
```

Navigation cluster:

```text
|          | Up       |          
             m,c,s,cs

| Left     | Down     | Right    
  m,c,s,cs   m,c,s,cs   m,c,s,cs

| PgUp     | PgDn     | Home     | End      
  m,c,s      m,c,s      m,c        m,c
```

Mouse/wheel binds:

```text
| WheelUp  | WheelDn  
  m,c,s,cs   m,c,s,cs

| WheelLt  | WheelRt  
  m,c        m,c
```
