class_name RSGameModule
extends Resource
## One sport's self-description, saved as game/scenes/<id>/<id>_module.tres. RSCatalog finds
## these files at startup; menus, tutorials, solo challenges and tools read them instead of
## hard-coded lists. Paths stay strings so the catalog never loads a game scene or texture.
## Text fields are Chinese translation keys (tr / RSLang.t). tools/catalog.py parses the same
## .tres text without Godot: keep the defaults below in sync with its DEFAULTS table.

const MODES := ["individual", "versus", "teams"]   ## 各打各的 / 同场对战 / 组队

@export var id := ""                    ## folder name; saves, records and party sessions use it
@export var name := ""                  ## Chinese title (translation key)
@export var oled := ""                  ## controller OLED title: ASCII capitals, at most 10
@export_file("*.tscn") var scene := ""  ## the RSPartyGame scene
@export_multiline var desc := ""        ## menu description (translation key)
## Script whose MAPS constant lists the maps ([{name, en, ...}], the same array the game's
## _maps() returns). Empty for a single-map game.
@export_file("*.gd") var maps_script := ""
## Lesson steps: names of RSTutorial step constants (TILT_RIGHT, THROW, ...), in order.
@export var lessons := PackedStringArray()
@export var solo_goals := PackedInt32Array()   ## three ascending map-1 score goals, one star each
@export var players := Vector2i(1, 4)   ## supported player count (min, max)
@export_enum("individual", "versus", "teams") var mode := "individual"
@export var ambience := ""              ## RSSfx id of the main ambience loop ("" = none)
@export_file("*.jpg") var preview := "" ## menu picture rendered by tools/capture_previews.py
@export var ready := false              ## listed in the menu, solo and party pages
@export var order := 100                ## menu position, ascending (ties sort by id)
@export var benchmark := false          ## one of the settings benchmark scenes (RSBenchmarkMenu)
