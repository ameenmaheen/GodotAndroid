extends Node3D

signal camera_view_changed(view_name: String)
signal camera_panel_visibility_changed(visible: bool)
signal door_state_changed(door_name: String, open: bool)
signal auto_rotate_changed(enabled: bool)
signal zoom_changed(fov: float)
signal paint_color_changed(color: Color)

@onready var pivot: Node3D = $CameraPivot
@onready var cam: Camera3D = $CameraPivot/Camera3D
@onready var bg: MeshInstance3D = $MeshInstance3D

const TAP_THRESHOLD := 12.0
const FOCUS_DURATION := 0.7
const ANDROID_BRIDGE_NAME := "CarBridge"
const AUTO_ROTATE_SPEED := 0.35 # radians per second
const MIN_CAMERA_FOV := 25.0
const MAX_CAMERA_FOV := 75.0

# Background (camera-locked so orbiting the car never moves it).
const BG_DISTANCE := 30.0   # how far in front of the camera the backdrop sits
const BG_ZOOM := 1.3        # >1 enlarges the image (gives room to shift it)
const BG_SHIFT_UP := 0.12   # fraction of screen height to move the image up

# Paint: exact material name(s) from the GLB. Add "Generic_gloss_black_trim"
# to also paint the roof / black trim.
const PAINT_MATERIAL_NAMES := ["Generic_body_paint"]
const PAINT_COLORS := {
	"Exotica Red": Color("821517"),
	"Galaxy Blue": Color("26457a"),
	"Grigio Magnesio Grey": Color("676A6A"),
	"Pearl White": Color("F5F7E3"),
	"Silvery Moon": Color("CED0D3"),
	"Techno Green Metallic": Color("69ac58"),
	"Forest green": Color("1f5a3a"),
	"Sunset orange": Color("e0661a"),
}

# GLB coordinates: vehicle front is +Z; steering wheel is on X+ side.
const CAMERA_PRESETS := {
"overview": {"target": Vector3(0.0, 0.90, -0.02), "offset": Vector3(4.01, 2.32, 4.35), "fov": 42.0},	"side": {"target": Vector3(0.0, 0.88, 0.0), "offset": Vector3(6.2, 1.45, 0.0), "fov": 42.0},
	"front": {"target": Vector3(0.0, 0.92, 1.83), "offset": Vector3(0.0, 1.15, 4.8), "fov": 43.0},
	"tire_fl": {"target": Vector3(0.76, 0.36, 1.27), "offset": Vector3(1.35, 0.58, 0.62), "fov": 39.0},
	"tire_fr": {"target": Vector3(-0.75, 0.36, 1.28), "offset": Vector3(-1.35, 0.58, 0.62), "fov": 39.0},
	"tire_rl": {"target": Vector3(0.76, 0.36, -1.36), "offset": Vector3(1.35, 0.58, -0.62), "fov": 39.0},
	"tire_rr": {"target": Vector3(-0.75, 0.36, -1.35), "offset": Vector3(-1.35, 0.58, -0.62), "fov": 39.0},
	"cabin": {"target": Vector3(0.34, 1.12, 0.58), "offset": Vector3(0.02, 0.13, -0.88), "fov": 70.0},
}

# The GLB contains these exact parent node names. Animate the parent pivot,
# not the individual mesh pieces underneath it.
const OPEN_ANGLES := {
	"Door_FL": {"axis": "y", "angle": -65.0, "label": "Front left"},
	"Door_FR": {"axis": "y", "angle": 65.0, "label": "Front right"},
	"Door_BL": {"axis": "y", "angle": -65.0, "label": "Rear left"},
	"Door_BR": {"axis": "y", "angle": 65.0, "label": "Rear right"},
	"Door_Trunk": {"axis": "x", "angle": 60.0, "label": "Tailgate / Trunk"},
}

var _press_pos := Vector2.ZERO
var _moved := false
var _mouse_down := false
var _mouse_press_pos := Vector2.ZERO
var _mouse_moved := false
var _touch_started_on_ui := false
var _mouse_started_on_ui := false
var _closed_rot: Dictionary = {}
var _is_open: Dictionary = {}
var _tweens: Dictionary = {}
var _focus_tween: Tween
var _current_view := "overview"
var _auto_rotate := false

var _views_panel: PanelContainer
var _views_reopen_button: Button
var _page_container: VBoxContainer
var _page_title: Label
var _back_button: Button
var _zoom_slider: HSlider
var _zoom_value_label: Label
var _auto_rotate_check: CheckBox
var _android_bridge: Object

var _paint_mats: Array[BaseMaterial3D] = []
var _paint_shared: Dictionary = {}   # original material -> one shared copy
var _paint_color := Color("b3121c")
var _color_tween: Tween


func _ready() -> void:
	_create_camera_controls()
	set_camera_panel_visible(false)
	_connect_android_bridge()
	_collect_paint_materials()
	_focus_view("overview", false)
	_attach_background_to_camera()


func _process(delta: float) -> void:
	if not is_instance_valid(cam) or not is_instance_valid(pivot):
		return
	if _auto_rotate:
		pivot.rotate_y(AUTO_ROTATE_SPEED * delta)
	cam.look_at(pivot.global_position, Vector3.UP)
	_fit_background_to_screen()
	if is_instance_valid(_zoom_slider):
		_zoom_slider.set_value_no_signal(cam.fov)
		if is_instance_valid(_zoom_value_label):
			_zoom_value_label.text = "%d°" % roundi(cam.fov)


# -----------------------------------------------------------------------------
# Public API - callable from other GDScript files or the Android host bridge.
# -----------------------------------------------------------------------------

func focus_view(view_name: String, animate: bool = true) -> void:
	_focus_view(view_name, animate)


func set_camera_panel_visible(visible: bool) -> void:
	if not is_instance_valid(_views_panel) or not is_instance_valid(_views_reopen_button):
		return
	_views_panel.visible = visible
	_views_reopen_button.visible = not visible
	camera_panel_visibility_changed.emit(visible)


func toggle_camera_panel() -> void:
	if is_instance_valid(_views_panel):
		set_camera_panel_visible(not _views_panel.visible)


func set_door_state(door_name: String, open: bool) -> void:
	if not OPEN_ANGLES.has(door_name):
		push_warning("Unknown door key: " + door_name)
		return
	# The imported GLB may be a sibling of this controller, so search the
	# active scene first and then fall back to this node's subtree.
	var scene_root := get_tree().current_scene
	var found: Node = null
	if scene_root != null:
		found = _find_named_node(scene_root, door_name)
	if found == null:
		found = _find_named_node(self, door_name)
	var door := found as Node3D
	if door == null:
		push_warning("Door pivot not found: " + door_name + ". Confirm the imported GLB instance is present and the pivot name matches exactly.")
		return
	print("DOOR TARGET [", door_name, "]: ", door.get_path())
	print("DOOR ROTATION BEFORE [", door_name, "]: ", door.rotation_degrees)
	_set_door(door, open)


func set_camera_zoom(fov: float) -> void:
	if not is_instance_valid(cam):
		return
	cam.fov = clampf(fov, MIN_CAMERA_FOV, MAX_CAMERA_FOV)
	zoom_changed.emit(cam.fov)


func set_auto_rotate(enabled: bool) -> void:
	_auto_rotate = enabled
	if is_instance_valid(_auto_rotate_check):
		_auto_rotate_check.set_pressed_no_signal(enabled)
	auto_rotate_changed.emit(enabled)


func rotate_camera(horizontal_delta: float, vertical_delta: float = 0.0) -> void:
	pivot.rotate_y(-horizontal_delta * 0.005)


func get_current_view() -> String:
	return _current_view


# -----------------------------------------------------------------------------
# Background: parented to the camera so it stays fixed on screen while the
# camera orbits the car, and scaled to always cover the screen.
# -----------------------------------------------------------------------------

func _attach_background_to_camera() -> void:
	if not is_instance_valid(bg) or not is_instance_valid(cam):
		return
	bg.reparent(cam, false)        # false: discard the old world transform
	bg.rotation = Vector3.ZERO     # face the camera exactly
	bg.position = Vector3(0.0, 0.0, -BG_DISTANCE)
	_fit_background_to_screen()


func _fit_background_to_screen() -> void:
	if not is_instance_valid(bg) or not is_instance_valid(cam) or bg.mesh == null:
		return
	var vp_size := get_viewport().get_visible_rect().size
	if vp_size.y <= 0.0:
		return
	var view_h := 2.0 * BG_DISTANCE * tan(deg_to_rad(cam.fov * 0.5))
	var view_w := view_h * (vp_size.x / vp_size.y)
	var mesh_size := bg.mesh.get_aabb().size
	if mesh_size.x <= 0.0 or mesh_size.y <= 0.0:
		return
	var s := maxf(view_w / mesh_size.x, view_h / mesh_size.y) * BG_ZOOM
	bg.scale = Vector3(s, s, s)
	bg.position = Vector3(0.0, view_h * BG_SHIFT_UP, -BG_DISTANCE)


# -----------------------------------------------------------------------------
# Paint colour
# -----------------------------------------------------------------------------

func set_paint_color(color: Color, animate: bool = true) -> void:
	_paint_color = color
	if _color_tween and _color_tween.is_valid():
		_color_tween.kill()
	var from: Array[Color] = []
	for m in _paint_mats:
		# A baked colour texture would tint the new colour, so drop it once.
		if m.albedo_texture != null:
			m.albedo_texture = null
			m.albedo_color = color
		from.append(m.albedo_color)
	if animate:
		_color_tween = create_tween()
		_color_tween.tween_method(_blend_paint.bind(from, color), 0.0, 1.0, 0.35)
	else:
		_blend_paint(1.0, from, color)
	paint_color_changed.emit(color)


func _blend_paint(t: float, from: Array, to: Color) -> void:
	for i in _paint_mats.size():
		_paint_mats[i].albedo_color = (from[i] as Color).lerp(to, t)


func _collect_paint_materials() -> void:
	_paint_mats.clear()
	_paint_shared.clear()
	var car := get_node_or_null("GenericSUV_v4_lights")
	if car == null:
		push_warning("Car node 'GenericSUV_v4_lights' not found")
		return
	_scan_for_paint(car)
	print("PAINT MATERIALS FOUND: ", _paint_mats.size())


func _scan_for_paint(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			for i in mi.mesh.get_surface_count():
				var mat := mi.get_active_material(i) as BaseMaterial3D
				if mat == null or not PAINT_MATERIAL_NAMES.has(mat.resource_name):
					continue
				# One shared copy per original, so every part changes together.
				if not _paint_shared.has(mat):
					var copy := mat.duplicate() as BaseMaterial3D
					_paint_shared[mat] = copy
					_paint_mats.append(copy)
				mi.set_surface_override_material(i, _paint_shared[mat])
	for child in node.get_children():
		_scan_for_paint(child)


# -----------------------------------------------------------------------------
# Panel UI. The main panel opens separate child pages for Views, Doors, Wheels,
# and Settings so the controls are not all displayed at once.
# -----------------------------------------------------------------------------

func _create_camera_controls() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)

	_views_panel = PanelContainer.new()
	_views_panel.name = "VehicleControlsPanel"
	_views_panel.anchor_left = 1.0
	_views_panel.anchor_right = 1.0
	_views_panel.anchor_top = 0.0
	_views_panel.anchor_bottom = 0.0
	_views_panel.offset_left = -332.0
	_views_panel.offset_right = -12.0
	_views_panel.offset_top = 12.0
	_views_panel.offset_bottom = -12.0
	_views_panel.custom_minimum_size = Vector2(320.0, 260.0)
	layer.add_child(_views_panel)

	# MarginContainer keeps all panel contents away from the panel edges.
	var panel_margin := MarginContainer.new()
	panel_margin.add_theme_constant_override("margin_left", 14)
	panel_margin.add_theme_constant_override("margin_right", 14)
	panel_margin.add_theme_constant_override("margin_top", 14)
	panel_margin.add_theme_constant_override("margin_bottom", 14)
	_views_panel.add_child(panel_margin)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	panel_margin.add_child(outer)

	var header := HBoxContainer.new()
	outer.add_child(header)
	_back_button = Button.new()
	_back_button.text = "‹"
	_back_button.custom_minimum_size = Vector2(42, 38)
	_back_button.pressed.connect(_show_panel_page.bind("home"))
	header.add_child(_back_button)

	_page_title = Label.new()
	_page_title.text = "VEHICLE CONTROLS"
	_page_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_page_title)

	var close_button := Button.new()
	close_button.text = "×"
	close_button.custom_minimum_size = Vector2(42, 38)
	close_button.tooltip_text = "Close controls"
	close_button.pressed.connect(set_camera_panel_visible.bind(false))
	header.add_child(close_button)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)
	_page_container = VBoxContainer.new()
	_page_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page_container.add_theme_constant_override("separation", 8)
	scroll.add_child(_page_container)

	_views_reopen_button = Button.new()
	_views_reopen_button.name = "OpenVehicleControlsButton"
	_views_reopen_button.text = "Vehicle ☰"
	_views_reopen_button.anchor_left = 1.0
	_views_reopen_button.anchor_right = 1.0
	_views_reopen_button.anchor_top = 0.0
	_views_reopen_button.anchor_bottom = 0.0
	_views_reopen_button.offset_left = -126.0
	_views_reopen_button.offset_right = -12.0
	_views_reopen_button.offset_top = 12.0
	_views_reopen_button.offset_bottom = 56.0
	_views_reopen_button.pressed.connect(set_camera_panel_visible.bind(true))
	layer.add_child(_views_reopen_button)
	_views_reopen_button.visible = false

	_show_panel_page("home")


func _clear_page() -> void:
	for child in _page_container.get_children():
		child.queue_free()


func _show_panel_page(page: String) -> void:
	_clear_page()
	_back_button.visible = page != "home"
	match page:
		"home":
			_page_title.text = "VEHICLE CONTROLS"
			_add_page_button("Camera views", "camera")
			_add_page_button("Doors", "doors")
			_add_page_button("Wheels", "wheels")
			_add_page_button("Paint color", "colors")
			_add_page_button("Settings", "settings")
		"camera":
			_page_title.text = "CAMERA VIEWS"
			_add_view_button("Overview", "overview")
			_add_view_button("Side", "side")
			_add_view_button("Front", "front")
			_add_view_button("Cabin / Dashboard", "cabin")
		"doors":
			_page_title.text = "DOOR CONTROLS"
			_add_door_row("Front left", "Door_FL")
			_add_door_row("Front right", "Door_FR")
			_add_door_row("Rear left", "Door_BL")
			_add_door_row("Rear right", "Door_BR")
			_add_door_row("Trunk / Tailgate", "Door_Trunk")
		"wheels":
			_page_title.text = "WHEEL FOCUS"
			_add_wheel_row("Front left wheel", "tire_fl")
			_add_wheel_row("Front right wheel", "tire_fr")
			_add_wheel_row("Rear left wheel", "tire_rl")
			_add_wheel_row("Rear right wheel", "tire_rr")
		"colors":
			_page_title.text = "PAINT COLOR"
			_add_color_controls()
		"settings":
			_page_title.text = "CAMERA SETTINGS"
			_add_settings_controls()


func _add_page_button(caption: String, page: String) -> void:
	var button := Button.new()
	button.text = caption + "  ›"
	button.custom_minimum_size = Vector2(0, 52)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(_show_panel_page.bind(page))
	_page_container.add_child(button)


func _add_view_button(caption: String, view_name: String) -> void:
	var button := Button.new()
	button.text = caption
	button.custom_minimum_size = Vector2(0, 46)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(_on_view_button_pressed.bind(view_name))
	_page_container.add_child(button)


func _on_view_button_pressed(view_name: String) -> void:
	focus_view(view_name)


func _add_door_row(caption: String, door_name: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	_page_container.add_child(row)
	var label := Label.new()
	label.text = caption
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	var open_button := Button.new()
	open_button.text = "Open"
	open_button.custom_minimum_size = Vector2(68, 42)
	open_button.pressed.connect(_execute_door_command.bind(door_name, true, "PANEL"))
	row.add_child(open_button)
	var close_button := Button.new()
	close_button.text = "Close"
	close_button.custom_minimum_size = Vector2(68, 42)
	close_button.pressed.connect(_execute_door_command.bind(door_name, false, "PANEL"))
	row.add_child(close_button)


# Both panel buttons and 3D touch use this one command path.
func _execute_door_command(door_name: String, open: bool, source: String = "UNKNOWN") -> void:
	print("DOOR COMMAND [", source, "]: ", door_name, " | Open: ", open)
	set_door_state(door_name, open)


func _add_wheel_row(caption: String, view_name: String) -> void:
	var row := HBoxContainer.new()
	_page_container.add_child(row)
	var label := Label.new()
	label.text = caption
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	var focus_button := Button.new()
	focus_button.text = "Focus"
	focus_button.custom_minimum_size = Vector2(90, 42)
	focus_button.pressed.connect(focus_view.bind(view_name))
	row.add_child(focus_button)


func _add_color_controls() -> void:
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	_page_container.add_child(grid)
	for color_name in PAINT_COLORS:
		var color: Color = PAINT_COLORS[color_name]
		var swatch := Button.new()
		swatch.custom_minimum_size = Vector2(56, 56)
		swatch.tooltip_text = color_name
		for state in ["normal", "hover", "pressed", "focus"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = color
			sb.set_corner_radius_all(28)
			sb.set_border_width_all(3 if state != "normal" else 1)
			sb.border_color = Color.WHITE if state != "normal" else Color(1, 1, 1, 0.35)
			swatch.add_theme_stylebox_override(state, sb)
		swatch.pressed.connect(set_paint_color.bind(color))
		grid.add_child(swatch)

	var custom_label := Label.new()
	custom_label.text = "Custom color"
	_page_container.add_child(custom_label)
	var picker := ColorPickerButton.new()
	picker.color = _paint_color
	picker.custom_minimum_size = Vector2(0, 44)
	picker.edit_alpha = false
	picker.color_changed.connect(set_paint_color.bind(false))
	_page_container.add_child(picker)


func _add_settings_controls() -> void:
	var zoom_heading := Label.new()
	zoom_heading.text = "Zoom"
	_page_container.add_child(zoom_heading)
	var zoom_row := HBoxContainer.new()
	_page_container.add_child(zoom_row)
	_zoom_slider = HSlider.new()
	_zoom_slider.min_value = MIN_CAMERA_FOV
	_zoom_slider.max_value = MAX_CAMERA_FOV
	_zoom_slider.step = 1.0
	_zoom_slider.value = cam.fov
	_zoom_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_zoom_slider.value_changed.connect(set_camera_zoom)
	zoom_row.add_child(_zoom_slider)
	_zoom_value_label = Label.new()
	_zoom_value_label.custom_minimum_size = Vector2(42, 0)
	_zoom_value_label.text = "%d°" % roundi(cam.fov)
	zoom_row.add_child(_zoom_value_label)

	_auto_rotate_check = CheckBox.new()
	_auto_rotate_check.text = "Auto rotate vehicle"
	_auto_rotate_check.button_pressed = _auto_rotate
	_auto_rotate_check.toggled.connect(set_auto_rotate)
	_page_container.add_child(_auto_rotate_check)

	var reset_zoom_button := Button.new()
	reset_zoom_button.text = "Reset zoom for this view"
	reset_zoom_button.custom_minimum_size = Vector2(0, 42)
	reset_zoom_button.pressed.connect(_reset_zoom_for_current_view)
	_page_container.add_child(reset_zoom_button)

	var hint := Label.new()
	hint.text = "Lower FOV = closer zoom. Auto rotate can be turned off at any time."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_page_container.add_child(hint)


func _reset_zoom_for_current_view() -> void:
	if CAMERA_PRESETS.has(_current_view):
		set_camera_zoom(float(CAMERA_PRESETS[_current_view]["fov"]))


# -----------------------------------------------------------------------------
# Camera preset transition.
# -----------------------------------------------------------------------------

func _focus_view(view_name: String, animate: bool = true) -> void:
	if not CAMERA_PRESETS.has(view_name):
		push_warning("Unknown camera view: " + view_name)
		return
	var preset: Dictionary = CAMERA_PRESETS[view_name]
	var target: Vector3 = preset["target"]
	var camera_offset: Vector3 = preset["offset"]
	var target_fov: float = preset["fov"]
	_current_view = view_name
	camera_view_changed.emit(view_name)
	if _focus_tween and _focus_tween.is_running():
		_focus_tween.kill()
	if not animate:
		pivot.position = target
		pivot.rotation = Vector3.ZERO
		cam.position = camera_offset
		cam.fov = target_fov
		cam.look_at(pivot.global_position, Vector3.UP)
		return
	_focus_tween = create_tween()
	_focus_tween.set_parallel(true)
	_focus_tween.set_trans(Tween.TRANS_CUBIC)
	_focus_tween.set_ease(Tween.EASE_IN_OUT)
	_focus_tween.tween_property(pivot, "position", target, FOCUS_DURATION)
	_focus_tween.tween_property(pivot, "rotation", Vector3.ZERO, FOCUS_DURATION)
	_focus_tween.tween_property(cam, "position", camera_offset, FOCUS_DURATION)
	_focus_tween.tween_property(cam, "fov", target_fov, FOCUS_DURATION)


# -----------------------------------------------------------------------------
# Android bridge signals. Kotlin host plugin singleton name: CarBridge.
# -----------------------------------------------------------------------------

func _connect_android_bridge() -> void:
	if not Engine.has_singleton(ANDROID_BRIDGE_NAME):
		print("CarBridge not present; local Godot controls remain available")
		return
	_android_bridge = Engine.get_singleton(ANDROID_BRIDGE_NAME)
	_connect_bridge_signal("view_command", Callable(self, "_on_bridge_view_command"))
	_connect_bridge_signal("panel_command", Callable(self, "_on_bridge_panel_command"))
	_connect_bridge_signal("door_command", Callable(self, "_on_bridge_door_command"))
	_connect_bridge_signal("orbit_command", Callable(self, "_on_bridge_orbit_command"))
	_connect_bridge_signal("zoom_command", Callable(self, "_on_bridge_zoom_command"))
	_connect_bridge_signal("auto_rotate_command", Callable(self, "_on_bridge_auto_rotate_command"))
	_connect_bridge_signal("color_command", Callable(self, "_on_bridge_color_command"))
	print("CarBridge connected")


func _connect_bridge_signal(signal_name: String, callback: Callable) -> void:
	if _android_bridge == null or not _android_bridge.has_signal(signal_name):
		return
	if not _android_bridge.is_connected(signal_name, callback):
		_android_bridge.connect(signal_name, callback)


func _on_bridge_view_command(view_name: String) -> void:
	focus_view(view_name)

func _on_bridge_panel_command(visible: bool) -> void:
	set_camera_panel_visible(visible)

func _on_bridge_door_command(door_name: String, open: bool) -> void:
	set_door_state(door_name, open)

func _on_bridge_orbit_command(delta_x: float, delta_y: float = 0.0) -> void:
	rotate_camera(delta_x, delta_y)

func _on_bridge_zoom_command(fov: float) -> void:
	set_camera_zoom(fov)

func _on_bridge_auto_rotate_command(enabled: bool) -> void:
	set_auto_rotate(enabled)

func _on_bridge_color_command(hex: String) -> void:
	set_paint_color(Color.html(hex))


# -----------------------------------------------------------------------------
# Door pivot lookup and animation. GLB contains parent nodes named exactly as
# the keys in OPEN_ANGLES (verified in the supplied GLB hierarchy).
# -----------------------------------------------------------------------------

func _find_named_node(root: Node, wanted_name: String) -> Node:
	for child in root.get_children():
		if child.name == wanted_name:
			return child
		var nested := _find_named_node(child, wanted_name)
		if nested != null:
			return nested
	return null


func _set_door(door: Node3D, open: bool) -> void:
	var key := String(door.name)
	if not OPEN_ANGLES.has(key):
		push_warning("No door animation configuration for: " + key)
		return
	if not _closed_rot.has(key):
		_closed_rot[key] = door.rotation
	if _tweens.has(key) and is_instance_valid(_tweens[key]):
		_tweens[key].kill()
	var target: Vector3 = _closed_rot[key]
	if open:
		var cfg: Dictionary = OPEN_ANGLES[key]
		var axis_index := ["x", "y", "z"].find(cfg["axis"])
		target[axis_index] = target[axis_index] + deg_to_rad(float(cfg["angle"]))
	_is_open[key] = open
	door_state_changed.emit(key, open)
	print("DOOR ANIMATION [", key, "]: ", door.get_path(),
		" | From: ", door.rotation_degrees,
		" | To: ", target * (180.0 / PI))
	# Bind the tween to the actual door node so its lifetime follows the
	# animated pivot, and report the final rotation when the tween completes.
	var tween := door.create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(door, "rotation", target, 0.8)
	tween.finished.connect(_on_door_tween_finished.bind(key, door, open))
	_tweens[key] = tween
	print("DOOR TWEEN STARTED [", key, "]: running=", tween.is_running(),
		" | target local rotation=", target * (180.0 / PI))


func _on_door_tween_finished(key: String, door: Node3D, open: bool) -> void:
	if not is_instance_valid(door):
		print("DOOR TWEEN FINISHED [", key, "]: target node was freed")
		return
	print("DOOR TWEEN FINISHED [", key, "]: open=", open,
		" | actual local rotation=", door.rotation_degrees,
		" | actual global rotation=", door.global_rotation_degrees)


# -----------------------------------------------------------------------------
# Input: touch/mouse drag orbits the car; key shortcuts aid desktop testing.
# Door controls in the Doors sub-panel work without physics collision shapes.
# -----------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	# Use _input rather than _unhandled_input so touch events are received
	# before GUI controls or other nodes can consume them. Touches beginning
	# over the controls panel are ignored so UI buttons remain unaffected.
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_started_on_ui = _is_over_controls_ui(event.position)
			_press_pos = event.position
			_moved = false
		elif not _touch_started_on_ui and not _moved:
			_try_pick(event.position)
		_touch_started_on_ui = false
	elif event is InputEventScreenDrag:
		if _touch_started_on_ui:
			return
		if event.position.distance_to(_press_pos) > TAP_THRESHOLD:
			_moved = true
		pivot.rotate_y(-event.relative.x * 0.005)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_mouse_started_on_ui = _is_over_controls_ui(event.position)
			_mouse_down = true
			_mouse_press_pos = event.position
			_mouse_moved = false
		else:
			_mouse_down = false
			if not _mouse_started_on_ui and not _mouse_moved:
				_try_pick(event.position)
			_mouse_started_on_ui = false
	elif event is InputEventMouseMotion and _mouse_down:
		if _mouse_started_on_ui:
			return
		if event.position.distance_to(_mouse_press_pos) > TAP_THRESHOLD:
			_mouse_moved = true
		pivot.rotate_y(-event.relative.x * 0.005)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1: focus_view("overview")
			KEY_2: focus_view("side")
			KEY_3: focus_view("front")
			KEY_4: focus_view("tire_fl")
			KEY_5: focus_view("tire_fr")
			KEY_6: focus_view("tire_rl")
			KEY_7: focus_view("tire_rr")
			KEY_8: focus_view("cabin")


func _is_over_controls_ui(screen_pos: Vector2) -> bool:
	if is_instance_valid(_views_panel) and _views_panel.visible:
		if _views_panel.get_global_rect().has_point(screen_pos):
			return true
	if is_instance_valid(_views_reopen_button) and _views_reopen_button.visible:
		if _views_reopen_button.get_global_rect().has_point(screen_pos):
			return true
	return false

func _try_pick(screen_pos: Vector2) -> void:
	if not is_instance_valid(cam):
		return
	var from := cam.project_ray_origin(screen_pos)
	var to := from + cam.project_ray_normal(screen_pos) * 100.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 0xFFFFFFFF
	query.collide_with_bodies = true
	query.collide_with_areas = true

	# A body panel or another vehicle collider can be in front of a door.
	# If the first hit is not part of a named door, exclude it and continue
	# along the same ray until a door collider is found or the ray is clear.
	var excluded_rids: Array[RID] = []
	var space_state := get_world_3d().direct_space_state
	for attempt in range(20):
		query.exclude = excluded_rids
		var hit := space_state.intersect_ray(query)
		if hit.is_empty():
			return

		var hit_object: Object = hit.get("collider")
		var node := hit_object as Node
		while node != null and not OPEN_ANGLES.has(String(node.name)):
			node = node.get_parent()
		if node is Node3D:
			var door_name := String(node.name)
			print("Door touch detected: ", door_name)

			# Toggle the tracked state, then call the exact same command
			# handler used by the panel Open/Close buttons.
			var new_state: bool = not _is_open.get(door_name, false)
			_execute_door_command(door_name, new_state, "TOUCH")
			return

		if hit_object is CollisionObject3D:
			excluded_rids.append((hit_object as CollisionObject3D).get_rid())
		else:
			return

	print("Door touch: no named door collider found along ray")
