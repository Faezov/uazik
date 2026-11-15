extends Node3D

# RPM anchors are tuning estimates for edited field-recording loops, not dyno data.
const LOOP_PATHS = ["res://audio/uaz_idle.wav", "res://audio/uaz_medium.wav", "res://audio/uaz_high.wav"]
const LOOP_RPM = [900.0, 1800.0, 3600.0]
@export var startup: AudioStream
@export var shutdown: AudioStream
var vehicle
var fallback: AudioStreamPlayer
var layers: Array[AudioStreamPlayer3D] = []
var one_shot: AudioStreamPlayer3D
var filter := AudioEffectLowPassFilter.new()
var bus_name: StringName
var running := true
var envelope := 0.0
var load_level := 0.0
var radio_mix := 0.0

func setup(car: VehicleBody3D, old_sound: AudioStreamPlayer) -> void:
	vehicle = car
	fallback = old_sound
	position = Vector3(0,0.6,-0.8)
	var streams: Array[AudioStreamWAV] = []
	for path in LOOP_PATHS:
		if ResourceLoader.exists(path):
			var stream := load(path) as AudioStreamWAV
			if stream: streams.append(stream.duplicate())
	if streams.size()==3:
		# One built-in filter changes engine load character in both camera views.
		bus_name = StringName("UAZ Engine %s" % get_instance_id())
		AudioServer.add_bus()
		var bus := AudioServer.bus_count-1
		AudioServer.set_bus_name(bus,bus_name)
		AudioServer.set_bus_send(bus,&"SFX")
		AudioServer.add_bus_effect(bus,filter)
		for stream in streams:
			stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
			stream.loop_begin = 0
			stream.loop_end = roundi(stream.get_length()*stream.mix_rate)
			var player := make_player()
			player.bus = bus_name
			player.stream = stream
			player.volume_db = -80
			layers.append(player)
			player.play()
	else:
		fallback.volume_db = -80
		fallback.play()
	one_shot = make_player()
	one_shot.bus = bus_name if not bus_name.is_empty() else &"SFX"
	start()

func make_player() -> AudioStreamPlayer3D:
	var player := AudioStreamPlayer3D.new()
	# Keep crossfade gains intact when the cabin camera is close to the engine.
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
	player.max_db = 0.0
	player.max_distance = 80.0
	player.panning_strength = 0.5
	player.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	add_child(player)
	return player

func start() -> void:
	running = true
	if startup:
		one_shot.stream = startup
		one_shot.play()

func stop() -> void:
	running = false
	if shutdown:
		one_shot.stream = shutdown
		one_shot.play()

func _process(delta: float) -> void:
	if not is_instance_valid(vehicle): return
	var radio: Node = vehicle.get_parent().get_node_or_null("Radio")
	radio_mix = move_toward(radio_mix,1.0 if radio and radio.enabled else 0.0,delta/0.75)
	if not bus_name.is_empty():
		AudioServer.set_bus_volume_db(AudioServer.get_bus_index(bus_name),-5.0*radio_mix)
	var blend := 1-exp(-delta*12)
	var cranking := startup and one_shot.playing and one_shot.stream==startup
	envelope = lerpf(envelope,1.0 if running and not cranking else 0.0,1-exp(-delta*7))
	var load_target := absf(float(vehicle.throttle))
	if vehicle.shift_time>0: load_target *= 0.25
	load_level = lerpf(load_level,load_target,1-exp(-delta*8))
	# Read the drivetrain RPM directly: wheelspin and shifts already affect it.
	var rpm := maxf(float(vehicle.engine_rpm),650.0)
	if layers.is_empty():
		fallback.pitch_scale = lerpf(fallback.pitch_scale,rpm/1200.0,blend)
		fallback.volume_linear = envelope*db_to_linear(-22+load_level*4)
		return
	# Retain the throttle response; soften only its bright end while music is on.
	filter.cutoff_hz = minf(lerpf(1800,6500,load_level),lerpf(6500,4000,radio_mix))
	var weights: Array[float] = [0.0,0.0,0.0]
	var lower := 0 if rpm<LOOP_RPM[1] else 1
	var interval := log(rpm/LOOP_RPM[lower])/log(LOOP_RPM[lower+1]/LOOP_RPM[lower])
	# Narrow equal-power fades keep both audible loops close to their recorded pitch.
	var crossfade := smoothstep(0.35,0.65,interval)
	weights[lower] = sqrt(1-crossfade)
	weights[lower+1] = sqrt(crossfade)
	for i in range(layers.size()):
		var player := layers[i]
		player.pitch_scale = lerpf(player.pitch_scale,clampf(rpm/LOOP_RPM[i],0.65,1.55),blend)
		var gain := envelope*weights[i]*lerpf(0.48,0.9,load_level)
		player.volume_linear = lerpf(player.volume_linear,gain,blend)

func _exit_tree() -> void:
	for player in layers:
		player.stop()
		player.stream = null
	if is_instance_valid(one_shot):
		one_shot.stop()
		one_shot.stream = null
	if not bus_name.is_empty():
		AudioServer.remove_bus(AudioServer.get_bus_index(bus_name))
