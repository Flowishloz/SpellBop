# UI DESIGN SYSTEM — "Gen X Soft Club" / PS2 Y2K Clean-Tech

> The permanent style anchor for **every menu and UI overlay in Spell Bop**. Read this before you
> generate ANY new menu, panel, or button. The whole point is uniformity: if you follow the rules
> below, a screen you build in a year will sit seamlessly beside the ones built today.
>
> Visual target: early-2000s retro-futurism — Ridge Racer Type 4, Wipeout 3, Frutiger-Aero / "Soft
> Club" tech interfaces. **Light, minimal, dream-like, futuristic.** Light frosted translucent acrylic,
> icy blues + silvers + sterile whites, **soft rounded corners (~0.3 curve)**, crisp 1px grid-lines,
> smooth Helvetica-style type with strict tracking. NO pure-black voids, NO neon, **NO big heavy
> opaque containers** — buttons float as light rounded frosted elements; reserve frosted plates for
> framing a small cluster (a title, a dialog) and keep them snug to their content.
>
> SCOPE: this system styles **menus + the Cosmetics scene**. The **in-match HUD** (health bars, card
> hand, cast button, stack display) is deliberately OUT of scope — it is bespoke `_draw()` / tuned and
> will get its own dedicated pass. Do not retheme the HUD without an explicit ask.

---

## 1. The artifacts (what exists, where)

| File | What it is |
|------|-----------|
| `res://ui/main_theme.tres` | The universal `Theme`. Assign it once at a menu's root Control → it cascades to every standard Control below (Button, Label, Panel, PanelContainer, LineEdit). |
| `res://ui/fonts/Inter.ttf` (+ `Inter-OFL.txt`) | The font — Inter, a free **OFL** grotesque (Helvetica-adjacent). Variable font; weights are picked via FontVariation. |
| `res://ui/frosted_panel.gdshader` | The "translucent acrylic" frosted-glass shader. Put it on a `ColorRect` behind a UI cluster and the 3D diorama **blurs** through it. |
| `res://scripts/ui/y2k_ui_button.gd` | `class_name Y2KButton extends Button` — the standard button with the PS2 hover-snap + press-scanline micro-interactions. Use this for EVERY button. |
| `res://tests/gen_ui_theme.gd` | The **generator** that builds `main_theme.tres`. The single source of truth for the design tokens. Edit a token here and re-run to regenerate the theme (see §6). |
| `res://tests/probe_ui_theme.gd` | Headless smoke: theme loads, Y2KButton builds, home + settings menus construct. |

---

## 2. The palette (design tokens)

Defined as `const`s at the top of `tests/gen_ui_theme.gd`. Never hardcode menu colours that
contradict these — pull the look from the theme instead.

| Token | Colour | Use |
|-------|--------|-----|
| `IDLE_TEXT` | `(0.74, 0.81, 0.90)` light grey-blue | **Unfocused** text (the default) |
| `WHITE` | `(1, 1, 1)` stark white | **Focused / hovered** text — the "flash to white" |
| `HEADER_TEXT` | `(0.93, 0.97, 1.0)` icy white | Headers |
| `INK` | `(0.06, 0.09, 0.16)` near-black | Text on the inverted (near-white) pressed fill |
| `ACCENT` | `(0.55, 0.82, 1.0)` icy blue | Caret, focus ring, the Y2KButton ► cursor + scanline |
| `BORDER` | `(0.90, 0.95, 1.0, 0.55)` bright silver | The **1px** grid-line border |
| `PANEL_FILL` | `(0.84, 0.90, 0.99, 0.12)` | Airy frosted silver-white fill (the cheap, no-blur version) |
| `BTN_HOVER_FILL` | `(0.93, 0.97, 1.0, 0.28)` near-white | The hover "snap" |
| `BTN_PRESS_FILL` | `(0.93, 0.97, 1.0, 0.92)` near-white | The press **invert** |

Borders are **1px**. Corner radius is **~30px** — a soft rounded curve (the "~0.3" light/futuristic
look), set as `RADIUS`/`BTN_RADIUS` in the generator. Semantic colours are still allowed where they
carry meaning (the gold Coin / green Gem currency, a red error status) — they sit ON TOP of the icy
chrome, they don't replace it.

---

## 3. Typography

One font (Inter), three weights as `FontVariation`s, distinguished by weight + **tracking**
(`spacing_glyph`, the strict letter-spacing of the 90s-minimalist revival):

- **body** — wght 440, tracking 1 → `Label` default, `LineEdit`.
- **ui** — wght 520, tracking 2 → `Button` (the theme `default_font`).
- **header** — wght 660, tracking 8 → the header type variations.

Type variations (assign with `control.theme_type_variation`):

| Variation | Looks like | For |
|-----------|-----------|-----|
| `&"TitleLabel"` | header font, 72px, stark white | The big screen title |
| `&"HeaderLabel"` | header font, 56px, icy white | Section / item headers (e.g. the skin name) |
| `&"MutedLabel"` | body font, 24px, dim grey-blue | Captions, hints, fine print |

Per-instance `add_theme_font_size_override(&"font_size", n)` is fine for sizing — the variation still
supplies the font + colour. **Do not** set `modulate` on a Label to colour it; use the variation (or
a `font_color` override only for a genuine semantic colour).

---

## 4. How to build a new menu (the recipe)

```gdscript
const UI_THEME := preload("res://ui/main_theme.tres")
const FROST_SHADER := preload("res://ui/frosted_panel.gdshader")

func _build_ui() -> void:
    var ui := CanvasLayer.new()
    add_child(ui)

    # A CanvasLayer is NOT a Control, so the theme rides a full-rect root Control. IGNORE filter so
    # the root never eats clicks — child buttons are still hit-tested independently.
    var root := Control.new()
    root.set_anchors_preset(Control.PRESET_FULL_RECT)
    root.theme = UI_THEME
    root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    ui.add_child(root)

    # 1) Frosted plate FIRST (so it sits behind the cluster). The diorama blurs through it.
    root.add_child(_frost(Vector2(24, 28), Vector2(1032, 122)))

    # 2) A title via the type variation (no modulate).
    var title := Label.new()
    title.text = "MY SCREEN"
    title.theme_type_variation = &"TitleLabel"
    root.add_child(title)

    # 3) Buttons are ALWAYS Y2KButton.
    var play := Y2KButton.new()
    play.text = "PLAY"
    play.pressed.connect(_on_play)
    root.add_child(play)

func _frost(pos: Vector2, sz: Vector2) -> ColorRect:
    var r := ColorRect.new()
    r.position = pos ; r.size = sz
    r.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var m := ShaderMaterial.new()
    m.shader = FROST_SHADER
    m.set_shader_parameter(&"rect_size", sz)   # REQUIRED — drives the rounded-corner SDF mask
    r.material = m
    return r
```

Rules of thumb:
- **Every button is a `Y2KButton`.** It inherits the `Button` theme automatically (same native class)
  and adds the hover-snap + ►-cursor + press-scanline. For icon-only buttons (arrows, an ✕) set
  `btn.show_cursor = false` to suppress the ► while keeping the snap/scanline.
- **Prefer floating light buttons over containers.** Default to letting buttons float (each is its own
  light rounded frosted element). Only add a frosted plate (`_frost`) to frame a *small* cluster — a
  title block, a dialog — and keep it **snug to its content** (no big plate with blank space). Add it
  BEFORE the cluster's controls; it self-rounds (always pass `rect_size`). Tune per-plate with
  `material.set_shader_parameter(&"panel_alpha"/"blur_radius"/"corner_radius", …)` — e.g. a full locker
  panel uses `panel_alpha ≈ 0.95`, a slim title plate stays lighter.
- **Plain `Panel` / `PanelContainer`** already get a translucent frosted stylebox + 1px border from the
  theme (the cheap, no-blur acrylic). Use `_frost` only when you want the real diorama blur.
- **Don't fight the theme**: drop ad-hoc `add_theme_color_override`/`modulate` on standard text — the
  muted-grey-blue → white-on-focus behaviour is the look. Keep overrides for genuine semantics only.
- A `CanvasLayer` can't hold a `theme`; always put a themed root `Control` under it (see settings_menu
  for the pattern where the root is also toggled wholesale for show/hide).

---

## 5. Y2KButton micro-interactions (the PS2 feel)

- **Hover / focus** — instant **digital snap**: the theme flips the background to brighter silver
  (no smooth scaling), the button flashes over-bright for ~0.1 s, and a blocky **► cursor** pops in at
  the left edge. (`show_cursor = false` drops just the cursor.)
- **Press** — **punchy + immediate**: the theme inverts the colours (near-white fill, dark-ink text)
  and a bright **scanline** sweeps down the face.

It is Tween-driven and **container-safe** — it only animates child overlays + `modulate`, never a
layout-managed `position`, so it works absolutely-placed or inside a container. It reads its accent
from the `ACCENT` token. Don't reimplement button feedback ad-hoc; extend Y2KButton if you need more.

---

## 6. Changing the look (regenerate, don't hand-edit)

`main_theme.tres` is **generated** — do not hand-edit the `.tres`. To change a colour, font weight,
tracking, border, or radius:

1. Edit the token / setter in `res://tests/gen_ui_theme.gd`.
2. Re-run it:
   `<godot 4.6.3 console> --headless --path . -s res://tests/gen_ui_theme.gd`
3. It rewrites `res://ui/main_theme.tres`. Re-run `tests/probe_ui_theme.gd` + screenshot to confirm.

To make the theme **truly global** later (after the in-match HUD gets its own pass), set it
project-wide instead of per-root: `project.godot → [gui] theme/custom = "res://ui/main_theme.tres"`.
That one line makes EVERY Control in the game default to it. We keep it per-root for now so the HUD
stays on its current bespoke styling until its dedicated pass.

---

## 7. Determinism / safety

All of this is **presentation-only** — menus, theme, shader, button. It never touches the
deterministic sim (no `_save_state`, no `network_sync`, no fixed-point state), so it is rollback- and
online-safe by construction. The 20-suite determinism sweep stays bit-identical across any UI-theme
change. (Verified when this system landed.)

---

## 8. Engine gotchas (learned building this)

- **Variable-font weights**: Inter is a variable font; pick a weight with
  `FontVariation.variation_opentype = {"wght": <n>}` (the string-key form works in Godot 4.6) and set
  tracking with `FontVariation.spacing_glyph`. Confirmed rendering distinct weights in a screenshot.
- **Frosted blur reads the framebuffer**: `frosted_panel.gdshader` samples `hint_screen_texture`, so it
  blurs whatever was drawn before it in the same viewport — the 3D diorama (drawn first) blurs through
  the CanvasLayer UI. Keep the frosted ColorRect the **backmost** element of its cluster. It even works
  while the tree is paused (settings menu), because the last frame is still in the framebuffer.
- **Frosted plates round their own corners** via an SDF mask in the shader — you MUST set the
  `rect_size` uniform to the ColorRect's pixel size (the `_frost` helper does it) or the mask uses a
  stale default and the rounding looks wrong. `corner_radius` (default 34) is the curve.
- **Theme on a CanvasLayer**: impossible (not a Control). Ride a full-rect root Control.
- **`mouse_filter = IGNORE` on a parent** does NOT block its children from receiving input — use it on
  the themed root + frosted plates so only the actual buttons are hit-tested.
