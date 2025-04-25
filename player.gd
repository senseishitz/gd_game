extends CharacterBody2D

const WALK_SPEED : float = 80.0
const IN_AIR_MOVE_SPEED : float = 40.0
const HALF_ROLL_SPEED : float = 60.0
const ROLL_SPEED : float = 160.0
const MAX_ROLL_DISTANCE : float = 96.0
const MAX_FALL_SPEED : float = 192.0
const FALL_INCR : float = 512.0
const LAND_THRESHOLD : float = 128.0
const PLATFORMS_OFF_LENGTH : float = 0.1
const PIPE_MOVE_RATE : float = 0.75
const MAX_CAMERA_ALERTS : float = 3

const AUDIO_STEPS : Array = [
	preload("res://audio/sfx/step1.ogg"),
	preload("res://audio/sfx/step2.ogg"),
	preload("res://audio/sfx/step3.ogg")
]

@export_node_path("Camera2D") var path_camera

@onready var sprite : Sprite2D = $Sprite2D
@onready var sprite_smash_vase : Sprite2D = $Sprite2D_SmashVase
@onready var area_interact : Area2D = $Area2D_Interact
@onready var collision_standing : CollisionShape2D = $CollisionShape2D_Standing
@onready var collision_crouched : CollisionShape2D = $CollisionShape2D_Crouched
@onready var audio_step : AudioStreamPlayer2D = $Audio_Step
@onready var audio_roll : AudioStreamPlayer2D = $Audio_Roll
@onready var audio_land : AudioStreamPlayer2D = $Audio_Land
@onready var audio_vent_hit : AudioStreamPlayer2D = $Audio_VentHit
@onready var audio_vase_smash : AudioStreamPlayer2D = $Audio_VaseSmash
@onready var camera : Camera2D = get_node(path_camera)

enum State {NORMAL, CROUCHING_DOWN, CROUCHED, STANDING_UP, ENTERING_ROLL, ROLLING, LEAVING_ROLL, FALLING, LANDING, ENTERING_DOOR, LEAVING_DOOR, ENTERING_LIFT, SEARCHING, SWIPING, HACKING, IN_PIPE, SMASHING_VASE, CAUGHT, ESCAPING}

var current_state : int = State.NORMAL
var anim_index : float = 0.0
var door_destination : Node2D
var last_computer_used : Node2D
var thing_to_search : Node2D
var thing_to_steal : Node2D

var facing : Vector2 = Vector2.RIGHT
var roll_distance : float
var platforms_on_timer : float = 0.0

var lit : bool = false
var obscured : bool = false

var pipe_path_points : Array
var target_path_point_index : int
var pipe_source : Node2D
var pipe_destination : Node2D
var pipe_exit_facing : Vector2
var pipe_next_point_timer : float

var footstep_cooldown : float = 0.0

var ignore_inputs : bool = false

signal caught
signal started_hacking
signal escaped
signal vase_smashed

func can_interact() -> bool:
	return area_interact.has_overlapping_areas()

func update_camera_offset() -> void:
	camera.override = false
	var interactables : Array[Area2D] = area_interact.get_overlapping_areas()
	for interactable in interactables:
		if interactable.is_in_group(&"door"):
			door_destination = interactable.get_destination()
			var difference : Vector2 = door_destination.global_position - global_position
			if difference.length() > 100.0:
				camera.override = true
				camera.override_position = (global_position + door_destination.global_position) / 2.0

# This function assumes that we'll never be overlapping two or more interactables at once
func get_interact_action_label() -> String:
	if ignore_inputs or current_state != State.NORMAL:
		return &""
	var interactables : Array[Area2D] = area_interact.get_overlapping_areas()
	for interactable in interactables:
		if interactable.is_in_group(&"stealable"):
			return &"Steal"
		elif interactable.is_in_group(&"searchable") and !interactable.searched:
			return &"Search"
		elif interactable.is_in_group(&"hiding_place"):
			return &"Hide"
		elif interactable.is_in_group(&"door"):
			door_destination = interactable.get_destination()
			door_destination.make_outline_visible()
			return &"Enter"
		elif interactable.is_in_group(&"level_exit"):
			return &"Escape"
		elif interactable.is_in_group(&"computer") and !interactable.hacked:
			return &"Hack"
		elif interactable.is_in_group(&"readable"):
			return &"Read"
		elif interactable.is_in_group(&"light_toggle"):
			return &"Toggle Light"
		elif interactable.is_in_group(&"level3_vase"):
			return &"Get Even"
	return &""

func should_hud_update_visibility() -> bool:
	return current_state in [State.NORMAL, State.CROUCHING_DOWN, State.CROUCHED, State.STANDING_UP, State.ENTERING_ROLL, State.ROLLING, State.LEAVING_ROLL, State.FALLING, State.LANDING, State.SWIPING]

func can_be_spotted() -> bool:
	return current_state in [State.NORMAL, State.CROUCHING_DOWN, State.CROUCHED, State.STANDING_UP, State.ENTERING_ROLL, State.ROLLING, State.LEAVING_ROLL, State.FALLING, State.LANDING, State.SWIPING, State.HACKING, State.CAUGHT] and lit and !obscured and !ignore_inputs

func update_obscured() -> void:
	obscured = false
	for node in get_tree().get_nodes_in_group(&"obscurer"):
		if node.is_hiding_player():
			obscured = true

func seen() -> void:
	pass

func camera_alerted() -> void:
	catch()

func catch() -> void:
	current_state = State.CAUGHT
	anim_index = 0.0
	emit_signal(&"caught")

func stop_hacking(success : float) -> void:
	current_state = State.NORMAL
	anim_index = 0.0
	if success:
		last_computer_used.hacked = true

func enter_pipe(journey : Array, source : Node2D, destination : Node2D, exit_facing : Vector2) -> void:
	pipe_path_points = journey
	target_path_point_index = 0
	pipe_source = source
	pipe_destination = destination
	pipe_exit_facing = exit_facing
	pipe_next_point_timer = PIPE_MOVE_RATE
	collision_standing.set_deferred("disabled", true)
	collision_crouched.set_deferred("disabled", true)
	visible = false
	current_state = State.IN_PIPE

func escape() -> void:
	current_state = State.ESCAPING
	emit_signal("escaped")

func play_footstep_sound() -> void:
	if footstep_cooldown <= 0.0:
		audio_step.stream = AUDIO_STEPS.pick_random()
		audio_step.pitch_scale = randf_range(0.95, 1.05)
		audio_step.play()
		footstep_cooldown = 0.1

func try_to_interact() -> void:
	var interactables : Array[Area2D] = area_interact.get_overlapping_areas()
	if interactables.size() > 0:
		var interactable : Area2D = interactables[0]
		if interactable.is_in_group(&"door"):
			global_position = interactable.global_position
			door_destination = interactable.get_destination()
			current_state = State.ENTERING_DOOR
			anim_index = 0.0
			interactable.open()
		elif interactable.is_in_group(&"computer"):
			if !interactable.hacked:
				global_position = interactable.global_position
				current_state = State.HACKING
				anim_index = 0.0
				last_computer_used = interactable
				emit_signal(&"started_hacking")
		elif interactable.is_in_group(&"stealable"):
			thing_to_steal = interactable
			current_state = State.SWIPING
			anim_index = 0.0
		elif interactable.is_in_group(&"searchable"):
			if !interactable.searched:
				interactable.play_search_sound()
				thing_to_search = interactable
				current_state = State.SEARCHING
				anim_index = 0.0
		elif interactable.is_in_group(&"level3_vase"):
			global_position.x = interactable.global_position.x
			get_tree().call_group("game_camera", "zoom_in") # janky hack, m8
			var bgm_player : AudioStreamPlayer = get_tree().get_first_node_in_group("bgm_player")
			create_tween().tween_property(bgm_player, "pitch_scale", 0.25, 0.5)
			interactable.queue_free()
			current_state = State.SMASHING_VASE
			anim_index = 0.0
			sprite_smash_vase.show()
			sprite.hide()
			sprite.flip_h = true
			facing = Vector2.LEFT
		else:
			interactable.interact()

func on_ground() -> bool:
	var collision : KinematicCollision2D = move_and_collide(Vector2.DOWN * 0.25, true)
	return collision != null

func can_stand_up() -> bool:
	var collision : KinematicCollision2D = move_and_collide(Vector2.UP * 16, true)
	return collision == null

func do_horizontal_movement(movement_desired : float, speed : float, delta : float) -> void:
	sprite.flip_h = movement_desired < 0.0
	facing = Vector2.RIGHT if movement_desired > 0.0 else Vector2.LEFT
	var movement_direction : Vector2 = facing
	var downslope : bool = false
	var test_collision : KinematicCollision2D = move_and_collide(Vector2.DOWN, true)
	if test_collision != null:
		var test_normal : Vector2 = test_collision.get_normal().snapped(Vector2(0.25, 0.25))
		if (test_normal == Vector2(0.75, -0.75) and movement_desired == 1.0) or (test_normal == Vector2(-0.75, -0.75) and movement_desired == -1.0):
			downslope = true
			movement_direction.y = 1.0
	
	var collision : KinematicCollision2D = move_and_collide(movement_direction * delta * WALK_SPEED)
	if collision != null:
		var normal : Vector2 = collision.get_normal().snapped(Vector2(0.25, 0.25))
		if normal == Vector2(0.75, -0.75):
			move_and_collide(Vector2(-1, -1) * collision.get_remainder().length())
		elif normal == Vector2(-0.75, -0.75):
			move_and_collide(Vector2(1, -1) * collision.get_remainder().length())

func do_rolling_horizontal_movement(speed : float, delta : float) -> void:
	var collision : KinematicCollision2D = move_and_collide(facing * speed * delta)
	if collision != null:
		var normal : Vector2 = collision.get_normal().snapped(Vector2(0.25, 0.25))
		if normal == Vector2(0.75, -0.75):
			move_and_collide(Vector2(-1, -1) * collision.get_remainder().length())
		elif normal == Vector2(-0.75, -0.75):
			move_and_collide(Vector2(1, -1) * collision.get_remainder().length())
		elif normal in [Vector2.LEFT, Vector2.RIGHT]:
			facing.x *= -1.0
			sprite.flip_h = !sprite.flip_h

func do_rolling_fall(delta : float) -> void:
	if not on_ground():
		velocity.y = clampf(velocity.y + (FALL_INCR * delta), -MAX_FALL_SPEED, MAX_FALL_SPEED)
		var fall_collision : KinematicCollision2D = move_and_collide(velocity * delta)
		if fall_collision != null:
			if velocity.y > LAND_THRESHOLD:
				current_state = State.LEAVING_ROLL
				collision_standing.disabled = false
				collision_crouched.disabled = true
			anim_index = 0.0
			velocity.y = 0.0

func _physics_process_entering_door(delta : float) -> void:
	obscured = false
	anim_index += delta
	sprite.frame = 78 + clampf(anim_index * 4.0, 0.0, 1.0)
	sprite.modulate.a = clampf(2.0 - (anim_index * 4.0), 0.0, 1.0)
	if anim_index >= 1.0: # TODO: tweak this
		current_state = State.LEAVING_DOOR
		global_position = door_destination.global_position
		door_destination.open()
		anim_index = 0.0

func _physics_process_leaving_door(delta : float) -> void:
	obscured = false
	anim_index += delta * 4.0
	sprite.frame = 0
	sprite.modulate.a = anim_index
	if anim_index >= 1.0: # TODO: tweak this
		current_state = State.NORMAL
		sprite.modulate.a = 1.0

func _physics_process_crouching_down(delta : float) -> void:
	update_obscured()
	anim_index += delta * 15.0
	sprite.frame = 28 + clampf(anim_index, 0.0, 4.0)
	if anim_index >= 4.0:
		current_state = State.CROUCHED
		anim_index = 0.0
	if Input.is_action_just_pressed(&"interact") and !ignore_inputs:
		set_collision_mask_value(4, false)
		platforms_on_timer = PLATFORMS_OFF_LENGTH
	if not on_ground():
		current_state = State.FALLING
		anim_index = 0.0
		collision_standing.disabled = false
		collision_crouched.disabled = true
	else:
		set_collision_mask_value(4, true)
		if not Input.is_action_pressed(&"down"):
			current_state = State.STANDING_UP
			anim_index = 0.0
			collision_standing.disabled = false
			collision_crouched.disabled = true
		elif Input.is_action_pressed(&"right") and !ignore_inputs:
			sprite.flip_h = false
			facing = Vector2.RIGHT
			roll_distance = MAX_ROLL_DISTANCE
			current_state = State.ENTERING_ROLL
			anim_index = 0.0
			audio_roll.play()
		elif Input.is_action_pressed(&"left") and !ignore_inputs:
			sprite.flip_h = true
			facing = Vector2.LEFT
			roll_distance = MAX_ROLL_DISTANCE
			current_state = State.ENTERING_ROLL
			anim_index = 0.0
			audio_roll.play()

func _physics_process_crouched(delta : float) -> void:
	update_obscured()
	sprite.frame = 33
	if Input.is_action_just_pressed(&"interact") and !ignore_inputs:
		set_collision_mask_value(4, false)
		platforms_on_timer = PLATFORMS_OFF_LENGTH
	if not on_ground():
		current_state = State.FALLING
		anim_index = 0.0
		collision_standing.disabled = false
		collision_crouched.disabled = true
	else:
		set_collision_mask_value(4, true)
		if not Input.is_action_pressed(&"down"):
			current_state = State.STANDING_UP
			anim_index = 0.0
			collision_standing.disabled = false
			collision_crouched.disabled = true
		elif Input.is_action_pressed(&"right") and !ignore_inputs:
			sprite.flip_h = false
			facing = Vector2.RIGHT
			roll_distance = MAX_ROLL_DISTANCE
			current_state = State.ENTERING_ROLL
			anim_index = 0.0
			
			audio_roll.play()
		elif Input.is_action_pressed(&"left") and !ignore_inputs:
			sprite.flip_h = true
			facing = Vector2.LEFT
			roll_distance = MAX_ROLL_DISTANCE
			current_state = State.ENTERING_ROLL
			anim_index = 0.0
			audio_roll.play()

func _physics_process_standing_up(delta : float) -> void:
	update_obscured()
	anim_index += delta * 15.0
	sprite.frame = 34 + clampf(anim_index, 0.0, 1.0)
	if anim_index >= 2.0:
		current_state = State.NORMAL

func _physics_process_entering_roll(delta : float) -> void:
	update_obscured()
	anim_index += delta * 30.0
	sprite.frame = 84 + clampf(anim_index, 0.0, 1.0)
	if anim_index >= 2.0:
		current_state = State.ROLLING
		anim_index = 0.0
	if Input.is_action_just_pressed(&"down") and !ignore_inputs:
		set_collision_mask_value(4, false)
		platforms_on_timer = PLATFORMS_OFF_LENGTH
	do_rolling_horizontal_movement(HALF_ROLL_SPEED, delta)
	do_rolling_fall(delta)

func _physics_process_rolling(delta : float) -> void:
	update_obscured()
	anim_index += delta * 15.0
	sprite.frame = 86 + wrapf(anim_index, 0.0, 4.0)
	if Input.is_action_just_pressed(&"down") and !ignore_inputs:
		set_collision_mask_value(4, false)
		platforms_on_timer = PLATFORMS_OFF_LENGTH
	do_rolling_horizontal_movement(ROLL_SPEED, delta)
	do_rolling_fall(delta)
	roll_distance -= ROLL_SPEED * delta
	if (roll_distance <= 0.0 or (Input.is_action_just_pressed(&"interact") and !ignore_inputs)) and (on_ground() and can_stand_up()):
		current_state = State.LEAVING_ROLL
		anim_index = 0.0

func _physics_process_leaving_roll(delta : float) -> void:
	update_obscured()
	anim_index += delta * 15.0
	sprite.frame = 90 + clampf(anim_index, 0.0, 6.0)
	if anim_index >= 7.0:
		current_state = State.CROUCHED
		anim_index = 0.0
	if sprite.frame == 95 and footstep_cooldown <= 0.0:
		audio_land.play()
		footstep_cooldown = 0.1
	do_rolling_horizontal_movement(HALF_ROLL_SPEED, delta)
	do_rolling_fall(delta)

func _physics_process_normal(delta : float) -> void:
	update_camera_offset()
	obscured = false
	var movement_desired : float = Input.get_axis(&"left", &"right")
	if movement_desired != 0.0 and !ignore_inputs:
		do_horizontal_movement(movement_desired, WALK_SPEED, delta)
	if not on_ground():
		current_state = State.FALLING
		anim_index = 0.0
	elif Input.is_action_just_pressed(&"interact") and !ignore_inputs:
		try_to_interact()
	elif Input.is_action_just_pressed(&"down") and !ignore_inputs:
		current_state = State.CROUCHING_DOWN
		anim_index = 0.0
		collision_standing.disabled = true
		collision_crouched.disabled = false
	anim_index += delta * 10.0
	if movement_desired == 0.0 or ignore_inputs:
		sprite.frame = wrapf(anim_index, 0, 14)
	elif !ignore_inputs:
		sprite.frame = 14 + wrapf(anim_index, 0, 8)
	if sprite.frame in [17, 21]:
		play_footstep_sound()

func _physics_process_falling(delta : float) -> void:
	obscured = false
	anim_index += delta * 15.0
	sprite.frame = 98 + clampf(anim_index, 0.0, 1.0)
	if platforms_on_timer > 0.0:
		platforms_on_timer -= delta
	else:
		set_collision_mask_value(4, true)
	var movement_desired : float = Input.get_axis(&"left", &"right")
	if movement_desired != 0.0 and !ignore_inputs:
		do_horizontal_movement(movement_desired, IN_AIR_MOVE_SPEED, delta)
	velocity.y = clampf(velocity.y + (FALL_INCR * delta), -MAX_FALL_SPEED, MAX_FALL_SPEED)
	var fall_collision : KinematicCollision2D = move_and_collide(velocity * delta)
	if fall_collision != null:
		set_collision_mask_value(4, true)
		if velocity.y > LAND_THRESHOLD:
			if Input.is_action_pressed(&"down") and !ignore_inputs:
				collision_standing.disabled = true
				collision_crouched.disabled = false
				current_state = State.CROUCHED
			else:
				current_state = State.LANDING
			anim_index = 0.0
			velocity.y = 0.0
			audio_land.play()
		else:
			current_state = State.NORMAL

func _physics_process_landing(delta : float) -> void:
	update_obscured()
	anim_index += delta * 15.0
	sprite.frame = 100 + clampf(anim_index, 0.0, 4.0)
	if anim_index >= 5.0:
		current_state = State.NORMAL
		collision_standing.disabled = false
		collision_crouched.disabled = true

func _physics_process_hacking(delta : float) -> void:
	obscured = false
	anim_index += delta * 15.0
	sprite.frame = 42 + wrapf(anim_index, 0.0, 14.0)

func _physics_process_searching(delta : float) -> void:
	obscured = false
	anim_index += delta * 4.0
	sprite.frame = 78 + clampf(anim_index * 2.0, 0.0, 1.0)
	if anim_index >= 2.0:
		current_state = State.NORMAL
		anim_index = 0.0
		thing_to_search.search()

func _physics_process_swiping(delta : float) -> void:
	obscured = false
	anim_index += delta * 15.0
	sprite.frame = 56 + clampf(anim_index, 0.0, 10.0)
	if sprite.frame == 62 and thing_to_steal != null:
		thing_to_steal.steal()
		thing_to_steal = null
	if anim_index >= 11.0:
		current_state = State.NORMAL
		collision_standing.disabled = false
		collision_crouched.disabled = true

func _physics_process_in_pipe(delta : float) -> void:
	var target_point : Vector2 = pipe_source.global_position + pipe_path_points[target_path_point_index]
	if pipe_next_point_timer > 0.0:
		pipe_next_point_timer -= delta
	else:
		global_position = target_point
		target_path_point_index += 1
		pipe_next_point_timer = PIPE_MOVE_RATE
		audio_vent_hit.pitch_scale = randf_range(0.9, 1.1)
		audio_vent_hit.play()
		if target_path_point_index >= pipe_path_points.size():
			global_position = pipe_destination.global_position
			current_state = State.ROLLING
			anim_index = 0.0
			facing = pipe_exit_facing
			sprite.flip_h = facing == Vector2.LEFT
			collision_standing.disabled = false
			collision_crouched.disabled = true
			visible = true

func _physics_process_smashing_vase(delta : float) -> void:
	obscured = false
	anim_index += delta * 12.0
	sprite_smash_vase.frame = clampf(anim_index, 0.0, 23.0)
	if sprite_smash_vase.frame == 17 and not audio_vase_smash.playing:
		audio_vase_smash.play()
	if anim_index > 30.0:
		sprite_smash_vase.hide()
		sprite.show()
		current_state = State.NORMAL
		anim_index = 0.0
		emit_signal("vase_smashed")
		# janky hacks, m8
		get_tree().call_group("game_camera", "zoom_out")
		var bgm_player : AudioStreamPlayer = get_tree().get_first_node_in_group("bgm_player")
		create_tween().tween_property(bgm_player, "pitch_scale", 1.0, 0.5)

func _physics_process_caught(delta : float) -> void:
	obscured = false
	anim_index += delta * 15.0
	sprite.frame = 70 + clampf(anim_index, 0.0, 4.0)

func _physics_process(delta : float) -> void:
	match current_state:
		State.CROUCHING_DOWN: _physics_process_crouching_down(delta)
		State.CROUCHED: _physics_process_crouched(delta)
		State.STANDING_UP: _physics_process_standing_up(delta)
		State.NORMAL: _physics_process_normal(delta)
		State.ENTERING_ROLL: _physics_process_entering_roll(delta)
		State.ROLLING: _physics_process_rolling(delta)
		State.LEAVING_ROLL: _physics_process_leaving_roll(delta)
		State.FALLING: _physics_process_falling(delta)
		State.LANDING: _physics_process_landing(delta)
		State.ENTERING_DOOR: _physics_process_entering_door(delta)
		State.LEAVING_DOOR: _physics_process_leaving_door(delta)
		State.HACKING: _physics_process_hacking(delta)
		State.SEARCHING: _physics_process_searching(delta)
		State.SWIPING: _physics_process_swiping(delta)
		State.IN_PIPE: _physics_process_in_pipe(delta)
		State.SMASHING_VASE: _physics_process_smashing_vase(delta)
		State.CAUGHT: _physics_process_caught(delta)
	lit = false
	for illuminator in get_tree().get_nodes_in_group(&"illuminator"):
		if illuminator.is_lighting_player():
			lit = true
	footstep_cooldown -= delta
