enum Fixtures {
    /// Verbatim copy of ~/.config/kmonad/colemak.kbd (a kmonad file that must load with only warnings).
    static let kmonadColemak = #"""
(defcfg
  input  (iokit-name)
  output (kext)
  fallthrough true
)

(defsrc
  esc  f1   f2   f3   f4   f5   f6   f7   f8   f9   f10  f11  f12
  grv  1    2    3    4    5    6    7    8    9    0    -    =    bspc
  tab  q    w    e    r    t    y    u    i    o    p    [    ]    \
  caps a    s    d    f    g    h    j    k    l    ;    '    ret
  lsft z    x    c    v    b    n    m    ,    .    /    rsft up
  lctl lalt lmet           spc            rmet ralt left down right
)

(defalias
  ext (tap-hold-next-release 150 esc (layer-toggle extend))
  num (layer-toggle numpad)
)

(defalias
  cpy M-c
  pst M-v
  cut M-x
  udo M-z
  all M-a
  fnd M-f
  bk Back
  fw Forward
)

(deflayer colemak-dh
  _    brdn brup mctl spot dict dnd  prev pp   next mute vold volu
  _    1    2    3    4    5    6    7    8    9    0    -    =    _
  _    q    w    f    p    b    j    l    u    y    ;    [    ]    \\
  @ext a    r    s    t    g    m    n    e    i    o    '    _
  _    x    c    d    v    z    k    h    ,    .    /    _    _
  lctl lalt lmet           _            rmet ralt _    _    _
)

(deflayer extend
  _    play rewind previoussong nextsong ejectcd refresh brdn brup www mail prog1 prog2
  _    f1   f2   f3   f4   f5   f6   f7   f8   f9   f10  f11  f12  _
  _    esc  @bk  @fnd @fw  ins  _    home up   end  menu prnt slck _
  _    lalt lmet lsft lalt rctl pgup lft  down rght bks  caps ret
  _    @cut @cpy @pst tab  @udo pgdn del  lsft lctl comp _    _
  _    @num _    ret  _    _    _    _    _
)


(deflayer numpad
  _    _    _    _    _    _    _    _    _    _    _    _    _
  _    _    _    _    _    _    _    _    /    *    -    _    _    _
  _    _    _    _    _    _    _    7    8    9    +    _    _    _
  _    _    _    _    _    _    _    4    5    6    ret  _    _
  _    _    _    _    _    _    0    1    2    3    .    _    _
  _    _    _    _    _    _    _    _    _
)
"""#
}
