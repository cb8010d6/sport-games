class_name RSScoreboard
extends Node3D
## Shared physical scoreboard in metres: origin at the front-edge bottom centre, +Z faces
## the court. Text is supplied translated by callers; numeric labels use the shared font.
## No viewport or process loop. Content setters assign Label3D text only when it changes.

static var _panel_material: StandardMaterial3D
var _left: Label3D
var _right: Label3D
var _line: Label3D
var _text_updates := 0           ## actual assignments, also observable by data regressions


func _init(size: Vector2, title := "") -> void:
	if _panel_material == null:
		_panel_material = StandardMaterial3D.new()
		_panel_material.albedo_color = RSUi.SURFACE
		_panel_material.roughness = 0.4
		_panel_material.emission_enabled = true
		_panel_material.emission = Color(0.06, 0.12, 0.16)
		_panel_material.emission_energy_multiplier = 2.0
	var panel := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(size.x, size.y, 0.12)
	panel.mesh = box
	panel.material_override = _panel_material
	panel.position = Vector3(0, size.y * 0.5, -0.06)
	add_child(panel)
	var numeric_height := minf(size.y * 0.36, size.x * 0.2)
	_left = _label(RSUi.font_numeric(), Vector3(-size.x * 0.25, size.y * 0.52, 0.01), numeric_height)
	_right = _label(RSUi.font_numeric(), Vector3(size.x * 0.25, size.y * 0.52, 0.01), numeric_height)
	_line = _label(RSUi.font(), Vector3(0, size.y * 0.18, 0.01), size.y * 0.13)
	var heading := _label(RSUi.font(), Vector3(0, size.y * 0.85, 0.01), size.y * 0.15)
	_assign(heading, title)
	set_scores("0", "0")


func set_scores(left: String, right: String) -> void:
	_assign(_left, left)
	_assign(_right, right)


func set_line(text: String) -> void:
	_assign(_line, text)


func set_colors(left: Color, right: Color) -> void:
	if _left.modulate != left:
		_left.modulate = left
	if _right.modulate != right:
		_right.modulate = right


func _assign(label: Label3D, text: String) -> void:
	if label.text == text:
		return
	label.text = text
	_text_updates += 1


func _label(font: Font, at: Vector3, height: float) -> Label3D:
	var label := Label3D.new()
	label.font = font
	label.font_size = 120
	label.pixel_size = height / 120.0
	label.outline_size = 0
	label.modulate = RSUi.TEXT
	label.shaded = false
	label.double_sided = false
	label.position = at
	add_child(label)
	return label
