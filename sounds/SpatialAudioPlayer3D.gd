@tool
class_name SpatialAudioPlayer3D extends AudioStreamPlayer3D

"""
Surface Materials 
	-Values > 1.0 will start to override other ray reflection values, for example a carpet will cancel out reflections in a room
	-Add more materials as needed
	-Add the collision bodies to the material group
	-Only add materials that are actually needed to reduce the material lookup time
	
Example:
	If your wall is made of wood and is a StaticBody, add it to the WOOD group and make sure its collision layer matches audio_collision_layers
"""
var _surface_materials = [
	{"type" : "DEFAULT", "absorption" : 0.5}, 	#Add more values to this map to control other types of audio effects (other than absorption)
	{"type" : "WOOD", "absorption" : 1.0}, 		#WOOD is very good at sound absorption so it gets a full 1.0
	{"type" : "STONE", "absorption" : 0.0},		#STONE reflects sound quite a bit so it does not get any absorption
	{"type" : "CARPET", "absorption" : 2.0},	#CARPET even cancels out reflective walls so it gets a value greater than 1.0
]

## How far the spatial audio player will cast a ray to determine ray distances and materials
@export var max_raycast_distance : float = 30.0
## How often the spatial audio player will update the audio effects
@export var update_frequency_seconds : float = 0.5
## The max amount of reverb wetness applied to the sound
@export var max_reverb_wetness : float = 0.5	
## The lowpass cuttof frequency as if the listener is standing directly behind a wall. If the listener is far beyond a wall, the cutoff amount will be much lower than this value
@export var wall_lowpass_cutoff_amount : int = 600
## Controls how fast the effect will smoothly transition to the target value
@export var lerp_speed_modifier : float = 1.0
## The collision layers that affect spatial audio. Multiple collision layers can be used. The default Audio layer is 4 (because of the way it is lol)
@export var audio_collision_layers : Array[int] = [4]	

var _raycast_vector_array : Array = []					#Will contain all of the raycast vectors
var _distance_array : Array = [0,0,0,0,0,0,0,0,0,0] 	#The lazily updated distance array
var _material_array : Array = [] 						#The lazily updated material array
var _last_update_time : float = 0.0						#Time since the last spatial audio update
var _update_distances : bool = true						#Should distances be updated
var _current_raycast_index : int = 0					#The current raycast to be updated
var _collision_mask : int = 0xFFFFFFFF					#Raycasts expect a bit mask for collision layers but this is cumbersome to set as an export param

#Audio bus for this spatial audio player
var _audio_bus_idx = null
var _audio_bus_name = ""

#Effects
var _reverb_effect : AudioEffectReverb
var _lowpass_filter : AudioEffectLowPassFilter

#Target parameters (Will lerp over time)
var _target_lowpass_cutoff : float = 20000
var _target_reverb_room_size : float = 0.0
var _target_reverb_wetness : float = 0.0
var _target_volume_db : float = 0.0
var _target_pitch_scale : float = 1.0

func _ready():
	if !Engine.is_editor_hint():
		#Create an audio bus to control the effects
		_audio_bus_idx = AudioServer.bus_count
		_audio_bus_name = "SpatialBus#"+str(_audio_bus_idx)
		AudioServer.add_bus(_audio_bus_idx)
		AudioServer.set_bus_name(_audio_bus_idx,_audio_bus_name)
		AudioServer.set_bus_send(_audio_bus_idx,bus)
		self.bus = _audio_bus_name
		
		#Add the effects to the custom audio bus
		AudioServer.add_bus_effect(_audio_bus_idx,AudioEffectReverb.new(),0)
		_reverb_effect = AudioServer.get_bus_effect(_audio_bus_idx,0)
		AudioServer.add_bus_effect(_audio_bus_idx,AudioEffectLowPassFilter.new(),1)
		_lowpass_filter = AudioServer.get_bus_effect(_audio_bus_idx,1)
		
		#Capture the target volume, we will start from no sound and lerp to where it should be
		_target_volume_db = volume_db
		volume_db = -60.0
		
		#Capture the original target pitch scale
		_target_pitch_scale = pitch_scale
		
		#Initialize the raycast max distances
		_raycast_vector_array.append( Vector3(0,-max_raycast_distance,0) ) 												#down
		_raycast_vector_array.append( Vector3(max_raycast_distance,0,0) )												#left
		_raycast_vector_array.append( Vector3(-max_raycast_distance,0,0) ) 												#right
		_raycast_vector_array.append( Vector3(0,0,max_raycast_distance) ) 												#forward
		_raycast_vector_array.append( Vector3(0,0,max_raycast_distance).rotated(Vector3(0,1,0),deg_to_rad(45.0))) 		#forward left
		_raycast_vector_array.append( Vector3(0,0,max_raycast_distance).rotated(Vector3(0,1,0),deg_to_rad(-45.0)))		#forward right
		_raycast_vector_array.append( Vector3(0,0,-max_raycast_distance).rotated(Vector3(0,1,0),deg_to_rad(45.0)))		#backward right
		_raycast_vector_array.append( Vector3(0,0,-max_raycast_distance).rotated(Vector3(0,1,0),deg_to_rad(-45.0)))		#backward left
		_raycast_vector_array.append( Vector3(0,0,-max_raycast_distance) ) 												#backward
		_raycast_vector_array.append( Vector3(0,max_raycast_distance,0) ) 												#up
		
		#Initialize the material array with the default material
		for ray in _raycast_vector_array:
			_material_array.append(_surface_materials[0])
			
		#Set the collision mask
		_collision_mask = 0xFFFFFFFF
		for layer in audio_collision_layers:
			_collision_mask &= (1 << (layer-1)) 
			
		if autoplay:
			playing = true


func _physics_process(delta):
	if !Engine.is_editor_hint():
		_last_update_time += delta
		
		#Should we update the raycast distance values
		if _update_distances:
			_on_update_raycast_distance(_raycast_vector_array[_current_raycast_index], _current_raycast_index)
			_current_raycast_index += 1
			if _current_raycast_index >= _distance_array.size():
				_current_raycast_index = 0
				_update_distances = false
		
		#Check if we should update the spatial sound values
		if _last_update_time > update_frequency_seconds:
			var player_camera = get_viewport().get_camera_3d() #This might change over time
			if player_camera != null:
				_on_update_spatial_audio(player_camera)
			_update_distances = true
			_last_update_time = 0.0
		
		#lerp parameters for a smooth transition
		_lerp_parameters(delta)

func _lerp_parameters(delta):
	volume_db = lerp(volume_db,_target_volume_db,delta * lerp_speed_modifier)
	_lowpass_filter.cutoff_hz = lerp(_lowpass_filter.cutoff_hz,_target_lowpass_cutoff,delta * 5.0 * lerp_speed_modifier)
	_reverb_effect.wet = lerp(_reverb_effect.wet,_target_reverb_wetness * max_reverb_wetness,delta * 5.0 * lerp_speed_modifier)
	_reverb_effect.room_size = lerp(_reverb_effect.room_size,_target_reverb_room_size,delta * 5.0 * lerp_speed_modifier)
	pitch_scale = max(lerp(pitch_scale,_target_pitch_scale * Engine.time_scale,delta * 5.0 / Engine.time_scale),0.01 * lerp_speed_modifier)

func _on_update_raycast_distance(raycast_vector : Vector3, raycast_index : int):
	var query = PhysicsRayQueryParameters3D.create(self.global_position,self.global_position + raycast_vector, _collision_mask )
	var space_state = get_world_3d().direct_space_state
	var result = space_state.intersect_ray(query)
	if !result.is_empty():
		var ray_distance = self.global_position.distance_to(result["position"])
		var surface_material = _surface_materials[0]
		for material in _surface_materials:
			if result["collider"].is_in_group(material["type"]):
				surface_material = material
		_material_array[raycast_index] = surface_material
		_distance_array[raycast_index] = ray_distance
	else:
		_distance_array[raycast_index] = -1
		_material_array[raycast_index] = _surface_materials[0]


func _on_update_spatial_audio(player : Node3D):
	_on_update_reverb(player)
	_on_update_lowpass_filter(player)

func _on_update_lowpass_filter(_player : Node3D):
	if _lowpass_filter  != null:
		var query = PhysicsRayQueryParameters3D.create(self.global_position,self.global_position + (_player.global_position - self.global_position).normalized() * max_raycast_distance,_collision_mask )
		var space_state = get_world_3d().direct_space_state
		var result = space_state.intersect_ray(query)
		var lowpass_cutoff = 20000 #init to a value where nothing gets cutoff
		if !result.is_empty():
			var ray_distance = self.global_position.distance_to(result["position"])
			var distance_to_player = self.global_position.distance_to(_player.global_position)
			var wall_to_player_ratio = ray_distance / max(distance_to_player,0.001)
			if (ray_distance < distance_to_player) && (ray_distance < max_raycast_distance):
				lowpass_cutoff = wall_lowpass_cutoff_amount * wall_to_player_ratio
		_target_lowpass_cutoff = lowpass_cutoff


func _on_update_reverb(_player : Node3D):
	if _reverb_effect != null:
		#Find the reverb params
		var room_size = 0.0
		var wetness = 1.0
		for dist in _distance_array:
			if dist >= 0:
				#find the average room size based on the raycast distances that are valid
				room_size += (dist / max_raycast_distance) / (float(_distance_array.size()))
				room_size = min(room_size,1.0)
			else:
				#if a raycast did not hit anything we will reduce the reverb effect, almost no raycasts should hit when outdoors nowhere near buildings
				wetness -= 1.0 / float(_distance_array.size())
				wetness = max(wetness,0.0)
		
		#Remove wetness based on the surrounding area dampness (This seems to work better than using the built in reverb damping)
		for surface_material in _material_array:
			wetness -= surface_material["absorption"] / float(_distance_array.size())
			wetness = max(wetness,0.0)
		
		_target_reverb_wetness = wetness
		_target_reverb_room_size = room_size

func _enter_tree():
	scene_file_path = "res://sounds/SpatialAudioPlayer3D.tscn"
