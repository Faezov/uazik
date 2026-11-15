extends PanelContainer

const PATH = "user://audio.cfg"
const BUSES = [&"Music", &"SFX"]
const KEYS = ["music", "sfx"]
const DEFAULTS = [60.0, 30.0]
var menu: VBoxContainer
var options: VBoxContainer
var previous_pause := false
var previous_mouse := Input.MOUSE_MODE_VISIBLE

var config := ConfigFile.new()
var sliders: Array[HSlider] = []
var percentages: Array[Label] = []
var levels: Array[float] = []

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	hide()
	config.load(PATH)
	set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	offset_left = -220
	offset_right = 220
	offset_top = -110
	offset_bottom = 110
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color("17212bef")
	panel.border_color = Color("566879")
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(8)
	panel.content_margin_left = 24
	panel.content_margin_right = 24
	panel.content_margin_top = 20
	panel.content_margin_bottom = 20
	add_theme_stylebox_override("panel",panel)
	add_theme_color_override("font_color",Color("e4e1d4"))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation",14)
	add_child(column)
	menu = VBoxContainer.new()
	menu.add_theme_constant_override("separation", 14)
	column.add_child(menu)
	var heading := Label.new()
	heading.text = "PAUSED · До дома"
	heading.add_theme_font_size_override("font_size", 22)
	menu.add_child(heading)
	for caption in ["Resume", "Options", "Quit"]:
		var button := Button.new()
		button.text = caption
		button.custom_minimum_size.y = 40
		menu.add_child(button)
		match caption:
			"Resume": button.pressed.connect(toggle)
			"Options": button.pressed.connect(show_options)
			"Quit": button.pressed.connect(func(): get_tree().quit())
	options = VBoxContainer.new()
	options.add_theme_constant_override("separation", 14)
	column.add_child(options)
	column = options
	var title := Label.new()
	title.text = "Audio"
	title.add_theme_font_size_override("font_size",22)
	column.add_child(title)
	for i in range(BUSES.size()):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation",12)
		column.add_child(row)
		var caption := Label.new()
		caption.text = BUSES[i]
		caption.custom_minimum_size.x = 62
		row.add_child(caption)
		var slider := HSlider.new()
		slider.max_value = 100
		slider.step = 1
		slider.custom_minimum_size = Vector2(220,28)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.value = clampf(float(config.get_value("audio",KEYS[i],DEFAULTS[i])),0,100)
		row.add_child(slider)
		sliders.append(slider)
		var percentage := Label.new()
		percentage.custom_minimum_size.x = 48
		percentage.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		percentage.text = "%d%%" % slider.value
		row.add_child(percentage)
		percentages.append(percentage)
		levels.append(slider.value/100.0)
		AudioServer.set_bus_volume_linear(AudioServer.get_bus_index(BUSES[i]),levels[i])
		slider.value_changed.connect(_volume_changed.bind(i))
	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size.y = 40
	back.pressed.connect(show_main)
	column.add_child(back)
	options.hide()

func show_main() -> void:
	options.hide()
	menu.show()
	menu.get_child(1).grab_focus()

func show_options() -> void:
	menu.hide()
	options.show()
	sliders[0].grab_focus()

func toggle() -> void:
	if visible:
		hide()
		get_tree().paused = previous_pause
		Input.mouse_mode = previous_mouse
	else:
		previous_pause = get_tree().paused
		previous_mouse = Input.mouse_mode
		get_tree().paused = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		show()
		show_main()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key: int = event.physical_keycode if event.physical_keycode else event.keycode
		if key == KEY_ESCAPE:
			toggle()
			get_viewport().set_input_as_handled()

func _volume_changed(value: float, index: int) -> void:
	percentages[index].text = "%d%%" % value
	config.set_value("audio",KEYS[index],value)
	config.save(PATH)

func _process(delta: float) -> void:
	for i in range(BUSES.size()):
		var target := sliders[i].value/100.0
		levels[i] = lerpf(levels[i],target,1-exp(-delta*12))
		if absf(levels[i]-target)<0.0001: levels[i] = target
		AudioServer.set_bus_volume_linear(AudioServer.get_bus_index(BUSES[i]),levels[i])
