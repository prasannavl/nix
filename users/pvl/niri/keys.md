# Niri Key Map

Assumes local `config.kdl` includes `base-config.kdl` then `nix-config.kdl`;
`nix-config.kdl` includes `corner-rules.kdl`. Assumes no extra local overrides.

## Changed From Niri Defaults

| Action                                  | From                                           | To                                             |
| --------------------------------------- | ---------------------------------------------- | ---------------------------------------------- |
| move column/window left                 | `Mod+Ctrl+H`, `Mod+Ctrl+Left`                  | `Mod+Shift+H`, `Mod+Shift+Left`                |
| move window down                        | `Mod+Ctrl+J`, `Mod+Ctrl+Down`                  | `Mod+Shift+J`, `Mod+Shift+Down`                |
| move window up                          | `Mod+Ctrl+K`, `Mod+Ctrl+Up`                    | `Mod+Shift+K`, `Mod+Shift+Up`                  |
| move column right                       | `Mod+Ctrl+L`, `Mod+Ctrl+Right`                 | `Mod+Shift+L`, `Mod+Shift+Right`               |
| focus monitor left                      | `Mod+Shift+H`, `Mod+Shift+Left`                | `Mod+Ctrl+H`, `Mod+Ctrl+Left`                  |
| focus monitor down                      | `Mod+Shift+J`, `Mod+Shift+Down`                | `Mod+Ctrl+J`, `Mod+Ctrl+Down`                  |
| focus monitor up                        | `Mod+Shift+K`, `Mod+Shift+Up`                  | `Mod+Ctrl+K`, `Mod+Ctrl+Up`                    |
| focus monitor right                     | `Mod+Shift+L`, `Mod+Shift+Right`               | `Mod+Ctrl+L`, `Mod+Ctrl+Right`                 |
| move column to first/last               | `Mod+Ctrl+Home`, `Mod+Ctrl+End`                | `Mod+Shift+Home`, `Mod+Shift+End`              |
| move column to workspace up/down        | `Mod+Ctrl+Page_Up/Page_Down`, `Mod+Ctrl+I/U`   | `Mod+Shift+Page_Up/Page_Down`, `Mod+Shift+I/U` |
| move workspace up/down                  | `Mod+Shift+Page_Up/Page_Down`, `Mod+Shift+I/U` | `Mod+Ctrl+Page_Up/Page_Down`, `Mod+Ctrl+I/U`   |
| move column to workspace 1 ... 9        | `Mod+Ctrl+1` ... `Mod+Ctrl+9`                  | `Mod+Shift+1` ... `Mod+Shift+9`                |
| wheel move column to workspace up/down  | `Mod+Ctrl+WheelScrollUp/Down`                  | `Mod+Shift+WheelScrollUp/Down`                 |
| wheel focus column left/right           | `Mod+Shift+WheelScrollUp/Down`                 | `Mod+Ctrl+WheelScrollUp/Down`                  |
| horizontal wheel move column left/right | `Mod+Ctrl+WheelScrollLeft/Right`               | `Mod+Shift+WheelScrollLeft/Right`              |

## Added Shortcuts

| Action                          | Shortcut                               |
| ------------------------------- | -------------------------------------- |
| move workspace to monitor left  | `Mod+Ctrl+Alt+H`, `Mod+Ctrl+Alt+Left`  |
| move workspace to monitor down  | `Mod+Ctrl+Alt+J`, `Mod+Ctrl+Alt+Down`  |
| move workspace to monitor up    | `Mod+Ctrl+Alt+K`, `Mod+Ctrl+Alt+Up`    |
| move workspace to monitor right | `Mod+Ctrl+Alt+L`, `Mod+Ctrl+Alt+Right` |

## Launch And Session

- `Mod+Shift+Slash`: show hotkey overlay
- `Mod+T`: open foot
- `Mod+Return`: open wm-terminal with fallback
- `Mod+D`: open Noctalia launcher, fallback fuzzel
- `Mod+Escape`: lock with swaylock
- `Super+Alt+S`: toggle Orca
- `Mod+Shift+Escape`: toggle shortcut inhibitor
- `Mod+Shift+E`: quit Niri
- `Ctrl+Alt+Delete`: quit Niri
- `Mod+Shift+P`: power off monitors

## Directional Focus And Movement

### Left: `H` / `Left`

- `Mod+H`, `Mod+Left`: focus column left
- `Mod+Shift+H`, `Mod+Shift+Left`: move column left
- `Mod+Ctrl+H`, `Mod+Ctrl+Left`: focus monitor left
- `Mod+Ctrl+Shift+H`, `Mod+Ctrl+Shift+Left`: move column to monitor left
- `Mod+Ctrl+Alt+H`, `Mod+Ctrl+Alt+Left`: move workspace to monitor left

### Down: `J` / `Down`

- `Mod+J`, `Mod+Down`: focus window down
- `Mod+Shift+J`, `Mod+Shift+Down`: move window down
- `Mod+Ctrl+J`, `Mod+Ctrl+Down`: focus monitor down
- `Mod+Ctrl+Shift+J`, `Mod+Ctrl+Shift+Down`: move column to monitor down
- `Mod+Ctrl+Alt+J`, `Mod+Ctrl+Alt+Down`: move workspace to monitor down

### Up: `K` / `Up`

- `Mod+K`, `Mod+Up`: focus window up
- `Mod+Shift+K`, `Mod+Shift+Up`: move window up
- `Mod+Ctrl+K`, `Mod+Ctrl+Up`: focus monitor up
- `Mod+Ctrl+Shift+K`, `Mod+Ctrl+Shift+Up`: move column to monitor up
- `Mod+Ctrl+Alt+K`, `Mod+Ctrl+Alt+Up`: move workspace to monitor up

### Right: `L` / `Right`

- `Mod+L`, `Mod+Right`: focus column right
- `Mod+Shift+L`, `Mod+Shift+Right`: move column right
- `Mod+Ctrl+L`, `Mod+Ctrl+Right`: focus monitor right
- `Mod+Ctrl+Shift+L`, `Mod+Ctrl+Shift+Right`: move column to monitor right
- `Mod+Ctrl+Alt+L`, `Mod+Ctrl+Alt+Right`: move workspace to monitor right

### First / Last Column

- `Mod+Home`: focus first column
- `Mod+Shift+Home`: move column to first
- `Mod+End`: focus last column
- `Mod+Shift+End`: move column to last

## Workspaces

### Up / Down Workspace

- `Mod+Page_Down`, `Mod+U`: focus workspace down
- `Mod+Shift+Page_Down`, `Mod+Shift+U`: move column to workspace down
- `Mod+Ctrl+Page_Down`, `Mod+Ctrl+U`: move workspace down
- `Mod+Page_Up`, `Mod+I`: focus workspace up
- `Mod+Shift+Page_Up`, `Mod+Shift+I`: move column to workspace up
- `Mod+Ctrl+Page_Up`, `Mod+Ctrl+I`: move workspace up

### Numbered Workspaces

- `Mod+1` ... `Mod+9`: focus workspace 1 ... 9
- `Mod+Shift+1` ... `Mod+Shift+9`: move column to workspace 1 ... 9

## Mouse Wheel With `Mod`

- `Mod+WheelScrollDown`: focus workspace down
- `Mod+Shift+WheelScrollDown`: move column to workspace down
- `Mod+Ctrl+WheelScrollDown`: focus column right
- `Mod+Ctrl+Shift+WheelScrollDown`: move column right
- `Mod+WheelScrollUp`: focus workspace up
- `Mod+Shift+WheelScrollUp`: move column to workspace up
- `Mod+Ctrl+WheelScrollUp`: focus column left
- `Mod+Ctrl+Shift+WheelScrollUp`: move column left
- `Mod+WheelScrollRight`: focus column right
- `Mod+Shift+WheelScrollRight`: move column right
- `Mod+WheelScrollLeft`: focus column left
- `Mod+Shift+WheelScrollLeft`: move column left

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
- `Shift+Print`: screenshot screen
- `Alt+Print`: screenshot window
- `Ctrl+Print`: interactive screenshot to clipboard only
- `Ctrl+Shift+Print`: screenshot screen to clipboard only
- `Ctrl+Alt+Print`: screenshot window to clipboard only
- `Mod+X`: interactive screenshot
- `Mod+Shift+X`: screenshot screen
- `Mod+Alt+X`: screenshot window
- `Mod+Ctrl+X`: interactive screenshot to clipboard only
- `Mod+Ctrl+Shift+X`: screenshot screen to clipboard only
- `Mod+Ctrl+Alt+X`: screenshot window to clipboard only

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
- `ca`: `Mod+Ctrl+Alt+Key`
- `-`: unused with `Mod`

```text
| Esc      |          | Print    | S+Prt    | C+Prt    | C+S+Prt  | A+Prt    | C+A+Prt  | C+A+Del  | S+A+L    | S+A+S    
  m                     shot       shot       clip       clip       shot       clip                 quit       lock       orca

| `        | 1        | 2        | 3        | 4        | 5        | 6        | 7        | 8        | 9        | 0        | -        | =        | Backspace 
  -          m,s        m,s        m,s        m,s        m,s        m,s        m,s        m,s        m,s        -          m,s        m,s        -

| Tab  | Q        | W        | E        | R        | T        | Y        | U        | I        | O        | P        | [        | ]        | \        
  -      m          m,s        s          m,c,s      m          m,c        m,c,s      m,c,s      m          s          m          m          -

| Caps | A        | S        | D        | F        | G        | H        | J        | K        | L        | ;        | '        | Enter 
  -      -          -          m          m,c,s      -          m,c,s,cs,ca m,c,s,cs,ca m,c,s,cs,ca m,c,s,cs,ca -          -          -

| Shift | Z        | X        | C        | V        | B        | N        | M        | ,        | .        | /        | Shift 
  -       m          m,c,s,cs,ca -          m,s        -          -          s          m          m          s          -
```

Navigation cluster:

```text
|          | Up       |          
             m,c,s,cs,ca

| Left     | Down     | Right    
  m,c,s,cs,ca m,c,s,cs,ca m,c,s,cs,ca

| PgUp     | PgDn     | Home     | End      
  m,c,s      m,c,s      m,s        m,s
```

Mouse/wheel binds:

```text
| WheelUp  | WheelDn  
  m,c,s,cs   m,c,s,cs

| WheelLt  | WheelRt  
  m,s        m,s
```
