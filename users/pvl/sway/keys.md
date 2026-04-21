# Sway Key Map

Assumes the Sway config from `users/pvl/sway/config.nix`.

## Launch And Session

- `Mod+Return`: open Alacritty
- `Mod+Space`: open fuzzel executable runner
- `Mod+D`: open Noctalia launcher, fallback fuzzel
- `Mod+Shift+D`: open wmenu
- `Mod+Escape`: lock with swaylock
- `Mod+Shift+Escape`: disable shortcut inhibitor
- `Mod+Shift+C`: reload Sway
- `Mod+Shift+E`: exit Sway
- `Mod+Alt+G`: reset AMD GPU

## Directional Focus And Movement

### Left: `H` / `Left`

- `Mod+H`, `Mod+Left`: focus left
- `Mod+Shift+H`, `Mod+Shift+Left`: move container left
- `Mod+Ctrl+Left`: previous workspace
- `Mod+Ctrl+Shift+Left`: move workspace to output left
- `Mod+Alt+Left`: shrink width by 10 ppt

### Down: `J` / `Down`

- `Mod+J`, `Mod+Down`: focus down
- `Mod+Shift+J`, `Mod+Shift+Down`: move container down

### Up: `K` / `Up`

- `Mod+K`, `Mod+Up`: focus up
- `Mod+Shift+K`, `Mod+Shift+Up`: move container up

### Right: `L` / `Right`

- `Mod+L`, `Mod+Right`: focus right
- `Mod+Shift+L`, `Mod+Shift+Right`: move container right
- `Mod+Ctrl+Right`: next workspace
- `Mod+Ctrl+Shift+Right`: move workspace to output right
- `Mod+Alt+Right`: grow width by 10 ppt

## Workspaces

- `Mod+1` ... `Mod+9`, `Mod+0`: focus workspace 1 ... 10
- `Mod+Shift+1` ... `Mod+Shift+9`, `Mod+Shift+0`: move container to workspace 1
  ... 10
- `swipe:3:left`: next workspace
- `swipe:3:right`: previous workspace

## Window And Layout

- `Mod+Q`: close focused container
- `Mod+Ctrl+Space`: toggle tiling/floating focus
- `Mod+Shift+Space`: toggle floating
- `Mod+Alt+Space`: toggle sticky
- `Mod+B`: split horizontal
- `Mod+V`: split vertical
- `Mod+S`: layout stacking
- `Mod+W`: layout tabbed
- `Mod+E`: toggle split layout
- `Mod+F`: fullscreen
- `Mod+A`: focus parent
- `Mod+Minus`: show scratchpad
- `Mod+Shift+Minus`: move to scratchpad
- `Mod+R`: enter resize mode

## Screenshots

- `Print`: save interactive screenshot
- `Shift+Print`: save output screenshot
- `Alt+Print`: save active-window screenshot
- `Ctrl+Print`: copy interactive screenshot
- `Ctrl+Shift+Print`: copy output screenshot
- `Ctrl+Alt+Print`: copy active-window screenshot
- `Mod+X`: save interactive screenshot
- `Mod+Shift+X`: save output screenshot
- `Mod+Alt+X`: save active-window screenshot
- `Mod+Ctrl+X`: copy interactive screenshot
- `Mod+Ctrl+Shift+X`: copy output screenshot
- `Mod+Ctrl+Alt+X`: copy active-window screenshot

## Resize Mode

- `H`, `Left`: shrink width by 10 px
- `J`, `Down`: grow height by 10 px
- `K`, `Up`: shrink height by 10 px
- `L`, `Right`: grow width by 10 px
- `Ctrl+Left`: shrink width by 10 ppt
- `Ctrl+Down`: grow height by 10 ppt
- `Ctrl+Up`: shrink height by 10 ppt
- `Ctrl+Right`: grow width by 10 ppt
- `Shift+Left`: shrink width by 33 ppt
- `Shift+Down`: grow height by 33 ppt
- `Shift+Up`: shrink height by 33 ppt
- `Shift+Right`: grow width by 33 ppt
- `Return`, `Escape`: leave resize mode

## Audio, Brightness, Lid

- `XF86AudioMute`: mute output
- `XF86AudioLowerVolume`: volume down
- `XF86AudioRaiseVolume`: volume up
- `XF86AudioMicMute`: mute microphone
- `XF86MonBrightnessDown`: brightness down
- `XF86MonBrightnessUp`: brightness up
- `lid:on`: power off outputs and lock
- `lid:off`: power on outputs

## Mod Key Occupancy

Legend:

- `m`: `Mod+Key`
- `c`: `Mod+Ctrl+Key`
- `s`: `Mod+Shift+Key`
- `cs`: `Mod+Ctrl+Shift+Key`
- `a`: `Mod+Alt+Key`
- `-`: unused with `Mod`

```text
| Esc      | Print    
  m,s        grim

| `        | 1        | 2        | 3        | 4        | 5        | 6        | 7        | 8        | 9        | 0        | -        | =        | Backspace 
  -          m,s        m,s        m,s        m,s        m,s        m,s        m,s        m,s        m,s        m,s        m,s        -          -

| Tab  | Q        | W        | E        | R        | T        | Y        | U        | I        | O        | P        | [        | ]        | \        
  -      m          m          m,s        m          -          -          -          -          -          m,c,s,cs   -          -          -

| Caps | A        | S        | D        | F        | G        | H        | J        | K        | L        | ;        | '        | Enter 
  -      m          m          m,s        m          m,a        m,s        m,s        m,s        m,s        -          -          m

| Shift | Z        | X        | C        | V        | B        | N        | M        | ,        | .        | /        | Shift 
  -       m,c        m          s          m          m          -          -          -          -          -          -
```

Navigation cluster:

```text
          | Up          
            m,s

| Left        | Down        | Right       
  m,c,s,cs,a    m,s           m,c,s,cs,a

| PgUp        | PgDn        | Home        | End         
  -             -             -             -
```

Space cluster:

```text
| Space       
  m,c,s,a
```

Resize mode cluster:

```text
| Esc     | Enter   
  exit      exit

| H       | J       | K       | L       
  width-    height+   height-   width+

| Left    | Down    | Up      | Right   
  width-    height+   height-   width+

| C+Left  | C+Down  | C+Up    | C+Right 
  width-    height+   height-   width+

| S+Left  | S+Down  | S+Up    | S+Right 
  width-    height+   height-   width+
```

Gestures, switches, media:

```text
| SwipeL  | SwipeR  | LidOn   | LidOff  
  ws next   ws prev   lock/off  on

| AudioMu | VolDn   | VolUp   | MicMute | BrDn    | BrUp    
  mute      vol-      vol+      mic       dim       bright
```
