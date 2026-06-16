## elements.gd — the VISUAL element identity of a spell (Sprint 23 batch 2, Creative Director).
##
## Every projectile carries one element (Fire / Spark / Ice). It is PURE PRESENTATION — it never
## touches the deterministic sim: it rides a projectile's spawn payload as a small int and is read
## ONLY by the impact VFX so a hit reads in the right colour (a fireball sprays orange, a spark bolt
## yellow, a frost wave blue). One source of truth for the element -> colour map, so the projectile
## burst, the struck-wizard sprite flash, and the launch muzzle flash all agree.
##
## The enum is index-aligned with SpellResource.element (@export_enum "Fire","Spark","Ice" = 0/1/2)
## and the casters thread that int into the spawn payload ("elem").
class_name Elements
extends Object

enum { FIRE, SPARK, ICE }


## Bright impact / spray / muzzle colour for a burst of this element (BurstFX albedo).
static func impact_color(element: int) -> Color:
	match element:
		SPARK:
			return Color(1.0, 0.9, 0.3, 0.95)    # electric yellow
		ICE:
			return Color(0.55, 0.8, 1.0, 0.95)   # frost blue
		_:
			return Color(1.0, 0.55, 0.2, 0.95)   # fire orange


## Sprite-modulate tint a struck wizard FLASHES in this element's colour. Lighter than impact_color
## (it multiplies the white sprite, so it must stay readable). Fire keeps the existing hot red-orange.
static func flash_color(element: int) -> Color:
	match element:
		SPARK:
			return Color(1.0, 0.93, 0.45)
		ICE:
			return Color(0.55, 0.8, 1.0)
		_:
			return Color(1.0, 0.5, 0.42)
