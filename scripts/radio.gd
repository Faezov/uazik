extends AudioStreamPlayer

const TRACKS = [
	preload("res://audio/radio/amaksi-lo-fi-loop-149702.mp3"),
	preload("res://audio/radio/artmylife-winter-lo-fi-458274.mp3"),
	preload("res://audio/radio/leberch-nostalgic-lofi-253219.mp3"),
]
# Match average loudness to the quietest supplied track; leave the files intact.
const TRACK_GAINS = [0.47,1.0,0.65]
const BUS_NAME = &"Radio"
var world: Node3D
var enabled := false
var track_index := 0
var changing_track := false
var fade := 0.0
var track_gain := 1.0
var low_pass := AudioEffectLowPassFilter.new()

func _ready() -> void:
	world = get_parent()
	process_mode = Node.PROCESS_MODE_ALWAYS
	AudioServer.add_bus()
	var radio_bus := AudioServer.bus_count-1
	AudioServer.set_bus_name(radio_bus,BUS_NAME)
	AudioServer.set_bus_send(radio_bus,&"Music")
	AudioServer.set_bus_volume_db(radio_bus,-22.0)
	var high_pass := AudioEffectHighPassFilter.new()
	high_pass.cutoff_hz = 150
	AudioServer.add_bus_effect(radio_bus,high_pass)
	low_pass.cutoff_hz = 2000
	AudioServer.add_bus_effect(radio_bus,low_pass)
	bus = BUS_NAME
	finished.connect(_on_finished)
	play_selected()

func _input(event: InputEvent) -> void:
	if get_parent().audio_settings.visible: return
	if not event is InputEventKey or not event.pressed or event.echo: return
	var key: int = event.physical_keycode if event.physical_keycode else event.keycode
	if key == KEY_M:
		enabled = not enabled
		if enabled and not playing: play_selected()
	elif key == KEY_N:
		track_index = (track_index+1)%TRACKS.size()
		changing_track = playing
		if not playing: play_selected()
	else:
		return
	get_viewport().set_input_as_handled()

func play_selected() -> void:
	fade = 0.0
	volume_linear = 0.0
	stream = TRACKS[track_index]
	stream.loop = false
	track_gain = TRACK_GAINS[track_index]
	if enabled: play()

func _on_finished() -> void:
	# A skip during the final fade must not advance the playlist twice.
	if not changing_track: track_index = (track_index+1)%TRACKS.size()
	changing_track = false
	play_selected()

func _process(delta: float) -> void:
	var target := 1.0 if enabled and not changing_track else 0.0
	fade = move_toward(fade,target,delta/0.5)
	volume_linear = fade*track_gain
	if fade==0.0:
		if changing_track:
			changing_track = false
			play_selected()
		elif not enabled and playing:
			stop()
	var cabin: bool = world.inside and world.camera.current
	low_pass.cutoff_hz = lerpf(low_pass.cutoff_hz,4500.0 if cabin else 2000.0,1-exp(-delta*6))

func _exit_tree() -> void:
	stop()
	stream = null
	var radio_bus := AudioServer.get_bus_index(BUS_NAME)
	if radio_bus>=0: AudioServer.remove_bus(radio_bus)
