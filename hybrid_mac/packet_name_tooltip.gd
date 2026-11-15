# macOS port add-on: shows the plant name under a hovered seed packet, as the original PvZ and the exe-based
# hybrid edition do. The Godot remake 0.31 has no such tooltip on any platform:
# TowerDefenseInGamePacketShow.OnMouseEntered only plays the preview animation inside the card.
#
# build_hybrid_app.sh adds this file to the app's copy of the pack as res://MacPort/packet_name_tooltip.gd and
# registers it as an autoload in Contents/MacOS/override.cfg (hybrid_mac/override.cfg).
# It only reads Godot properties of the game's C# nodes (packet.config, config.name -> tr()) and draws on its own
# CanvasLayer; it never changes game state. If a game update renames these, every lookup is null-checked and the
# tooltip simply does not appear.
extends CanvasLayer

const PACKET_SCRIPT_SUFFIX := "/TowerDefenseInGamePacketShow.cs"
const MAX_PARENT_HOPS := 6
const SHOW_DELAY := 0.15

var _panel: PanelContainer
var _label: Label
var _packet = null
var _hover_time := 0.0


func _ready() -> void:
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := StyleBoxFlat.new()
	box.bg_color = Color(1.0, 1.0, 0.78)
	box.border_color = Color(0, 0, 0)
	box.set_border_width_all(1)
	box.content_margin_left = 5
	box.content_margin_right = 5
	box.content_margin_top = 1
	box.content_margin_bottom = 1
	_panel.add_theme_stylebox_override("panel", box)
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_color_override("font_color", Color(0, 0, 0))
	_label.add_theme_font_size_override("font_size", 14)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel.add_child(_label)
	add_child(_panel)
	_panel.visible = false


func _find_packet(c: Node) -> Node:
	var n := c
	var hops := 0
	while n != null and hops <= MAX_PARENT_HOPS:
		var s = n.get_script()
		if s != null and String(s.resource_path).ends_with(PACKET_SCRIPT_SUFFIX):
			return n
		n = n.get_parent()
		hops += 1
	return null


func _hide() -> void:
	_panel.visible = false
	_packet = null
	_hover_time = 0.0


func _process(delta: float) -> void:
	var vp := get_viewport()
	var c := vp.gui_get_hovered_control()
	if c == null or not is_instance_valid(c) or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_hide()
		return
	var pkt = _find_packet(c)
	if pkt == null or not (pkt is CanvasItem) or not pkt.is_visible_in_tree():
		_hide()
		return
	var cfg = pkt.get("config")
	if cfg == null or not (cfg is Object):
		_hide()
		return
	var key = cfg.get("name")
	if typeof(key) != TYPE_STRING or key == "":
		_hide()
		return
	var text := tr(key)
	if text == key:
		_hide()
		return
	if pkt != _packet:
		_packet = pkt
		_hover_time = 0.0
		_panel.visible = false
	_hover_time += delta
	if _hover_time < SHOW_DELAY:
		return
	if _label.text != text:
		_label.text = text
		_panel.reset_size()
	# Place the tip centred under the hovered card, in base-viewport coordinates.
	var xf := (c as Control).get_global_transform_with_canvas()
	var r := Rect2(xf.origin, (c as Control).size * xf.get_scale())
	var vis := vp.get_visible_rect()
	var sz := _panel.get_combined_minimum_size()
	var pos := Vector2(r.get_center().x - sz.x * 0.5, r.end.y + 2.0)
	if pos.y + sz.y > vis.end.y:
		pos.y = r.position.y - sz.y - 2.0
	pos.x = clampf(pos.x, vis.position.x + 2.0, vis.end.x - sz.x - 2.0)
	_panel.position = pos
	_panel.visible = true
