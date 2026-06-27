extends CharacterBody2D

const NORMAL_ANIMATION_PREFIX := &"normal"

const BULLET_SCENE := preload("res://scene/bullet.tscn")
const ARMED_ANIMATION_PREFIX := &"armed"
const DEFAULT_FIRE_RATE_MULTIPLIER := 1.0
const SPIRAL_PHASE_STEP := PI / 12

const PLAYER_FORM_MODE_NORMAL := 0
const PLAYER_FORM_MODE_ARMED := 1
const SHOT_PATTERN_NORMAL := 0
const SHOT_PATTERN_SPIRAL := 1

# 角色动画节点，负责播放四方向移动动画
@onready var body_sprite: AnimatedSprite2D = $BodySprite
# 强化形态下显示的浮游炮特效
@onready var armed_effect_sprite: AnimatedSprite2D = $ArmedEffSprite
# 射击计时器，只负责限制开火频率
@onready var shooting_timer: Timer = $ShootingTimer

# 当前朝向后缀
var facing_suffix: StringName = &"right"
var last_pressed_direction: Vector2 = Vector2.ZERO

# 普通形态射速倍率
var rapid_fire_rate_multiplier: float = DEFAULT_FIRE_RATE_MULTIPLIER
# 强化形态射速倍率
var form_fire_rate_multiplier: float = DEFAULT_FIRE_RATE_MULTIPLIER
# 当前玩家形态模式，决定动画和射速倍率
var current_form_mode: int = PLAYER_FORM_MODE_NORMAL
# 当前弹幕形式
var current_shot_pattern: int = SHOT_PATTERN_NORMAL
# 螺旋弹幕的相位，用于计算旋转角度，让连续射击形成螺旋效果
var spiral_phase: float = 0.0

# 玩家移动速度，单位像素/秒
@export var move_speed: float = 120.0
# 玩家开火间隔，单位秒，越小开火越快
@export var fire_interval: float = 0.18
# 玩家子弹生成距离，单位像素，避免子弹出生在玩家身体内部
@export var bullet_spawn_distance: float = 16.0

func _ready() -> void:
	shooting_timer.one_shot = true
	shooting_timer.wait_time = _get_effective_fire_interval()
	_update_animation()
	_update_armed_effect()

func _physics_process(_delta: float) -> void:
	# 读取四个方向的输入，并得到标准化后的八向输入向量
	var move_input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var shot_input := Input.get_vector("shot_left", "shot_right", "shot_up", "shot_down")

	# CharacterBody2D的velocity属性用于控制移动速度，move_and_slide()方法会根据当前速度和碰撞信息更新位置
	velocity = move_input * move_speed
	move_and_slide()

	if current_shot_pattern == SHOT_PATTERN_SPIRAL:
		_try_auto_shoot_spiral()
	elif shot_input != Vector2.ZERO:
		_try_shoot(shot_input)

	if Input.is_action_just_pressed("move_up"):
		last_pressed_direction = Vector2.UP
	elif Input.is_action_just_pressed("move_down"):
		last_pressed_direction = Vector2.DOWN
	elif Input.is_action_just_pressed("move_left"):
		last_pressed_direction = Vector2.LEFT
	elif Input.is_action_just_pressed("move_right"):
		last_pressed_direction = Vector2.RIGHT

	_update_facing_direction(move_input, shot_input)
	_update_animation()
	_update_armed_effect()

# 根据当前朝向拼出动画名，并在动画实际变化时再切换播放
func _update_animation() -> void:
	var animation_name := StringName("%s_%s" % [_get_animation_prefix(), facing_suffix])

	if not body_sprite.sprite_frames.has_animation(animation_name):
		var fallback_animation := StringName("%s_%s" % [NORMAL_ANIMATION_PREFIX, facing_suffix])
		if not body_sprite.sprite_frames.has_animation(fallback_animation):
			push_warning("Animation '%s' not found in sprite frames." % animation_name)
			return
		animation_name = fallback_animation

	if body_sprite.animation != animation_name:
		body_sprite.play(animation_name)

# 射击方向优于移动方向，用于决定当前角色的面朝方向
# 自动螺旋弹幕期间不再读取射击输入，而是根据移动方向决定面朝方向
func _update_facing_direction(move_input: Vector2, shot_input: Vector2) -> void:
	if current_shot_pattern == SHOT_PATTERN_SPIRAL:
		if move_input != Vector2.ZERO:
			facing_suffix = _vector_to_facing_suffix(move_input)
		return
	
	if shot_input != Vector2.ZERO:
		facing_suffix = _vector_to_facing_suffix(shot_input)
	elif move_input != Vector2.ZERO:
		facing_suffix = _vector_to_facing_suffix(move_input)

# 尝试发射子弹，先检查冷却，再根据当前弹幕形式决定发射方式
func _try_shoot(shot_input: Vector2) -> void:
	if not shooting_timer.is_stopped():
		return

	var shoot_direction := shot_input.normalized()
	var if_spawned_bullet := _fire_bullet(shoot_direction)
	if if_spawned_bullet:
		shooting_timer.start(_get_effective_fire_interval())

# 根据当前弹幕形式决定发射方式，螺旋弹幕会同时发射两个相反方向的子弹，最终返回是否至少有一个子弹成功生成
func _fire_bullet(direction: Vector2) -> bool:
	if current_shot_pattern == SHOT_PATTERN_SPIRAL:
		var is_spawned_forward_bullet := _spawn_bullet(direction)
		var is_spawned_backward_bullet := _spawn_bullet(direction.rotated(PI))
		spiral_phase = wrapf(spiral_phase + SPIRAL_PHASE_STEP, 0.0, TAU)
		return is_spawned_forward_bullet or is_spawned_backward_bullet

	return _spawn_bullet(direction)

# 实例化并生成一发子弹
func _spawn_bullet(direction: Vector2) -> bool:
	var bullet := BULLET_SCENE.instantiate() as Bullet
	if bullet == null:
		return false

	bullet.top_level = true
	bullet.setup(direction)
	# 子弹挂载当前场景下，避免跟随玩家节点移动
	var spawn_parrent := get_tree().current_scene
	if spawn_parrent == null:
		return false

	spawn_parrent.add_child(bullet)
	bullet.global_position = global_position + direction * bullet_spawn_distance
	return true

# 螺旋形态下自动按照固定间隔朝360度旋转的方向发射子弹，形成螺旋弹幕效果
func _try_auto_shoot_spiral() -> void:
	if not shooting_timer.is_stopped():
		return

	var spiral_direction := Vector2.RIGHT.rotated(spiral_phase)
	var is_spawned_bullet := _fire_bullet(spiral_direction)
	if is_spawned_bullet:
		shooting_timer.start(_get_effective_fire_interval())

# 计算当前有效的开火间隔，射速倍率越高，开火间隔越短，最小间隔为0.01秒，避免过快导致性能问题
func _get_effective_fire_interval() -> float:
	return maxf(fire_interval / _get_effective_fire_rate_multiplier(), 0.01)

# 强化形态时使用强化形态的射速倍率，否则使用普通形态的射速倍率，最小倍率为0.01，避免除零错误
func _get_effective_fire_rate_multiplier() -> float:
	if _has_active_form_override():
		return maxf(form_fire_rate_multiplier, 0.01)

	return maxf(rapid_fire_rate_multiplier, 0.01)

# 只要玩家仍处于特殊形态或特殊弹幕模式，就视为强化模式仍然生效
func _has_active_form_override() -> bool:
	return (
		current_form_mode != PLAYER_FORM_MODE_NORMAL 
		or current_shot_pattern != SHOT_PATTERN_NORMAL
	)

# 根据当前形态选择动画前缀
func _get_animation_prefix() -> StringName:
	if current_form_mode == PLAYER_FORM_MODE_ARMED:
		return ARMED_ANIMATION_PREFIX
	
	return NORMAL_ANIMATION_PREFIX

# 强化螺旋形态下显示浮游炮动画，结束后隐藏并停止播放
func _update_armed_effect() -> void:
	var is_armed := current_form_mode == PLAYER_FORM_MODE_ARMED

	if not is_armed:
		if armed_effect_sprite.visible:
			armed_effect_sprite.visible = false
		if armed_effect_sprite.is_playing():
			armed_effect_sprite.stop()
		return

	if not armed_effect_sprite.visible:
		armed_effect_sprite.visible = true
	if armed_effect_sprite.is_playing():
		return
	if armed_effect_sprite.sprite_frames == null:
		return

	if armed_effect_sprite.sprite_frames.has_animation(&"default"):
		armed_effect_sprite.play(&"default")	

# 将任意二维向量映射为四个方向的后缀，用于选择动画
# 对角输入会根据最后按下的方向键决定动画，避免频繁切换
func _vector_to_facing_suffix(direction: Vector2) -> StringName:
	# 如果有对角线移动（同时按下两个键），根据最后按下的键决定动画
	if abs(direction.x) > 0 and abs(direction.y) > 0:
		# 检查最后按下的方向并返回对应动画
		if abs(last_pressed_direction.x) > abs(last_pressed_direction.y):
			# 最后按的是左右键
			return "right" if last_pressed_direction.x > 0.0 else "left"
		else:
			# 最后按的是上下键
			return "down" if last_pressed_direction.y > 0.0 else "up"
			
	# 如果没有对角线移动，根据当前输入的方向决定动画
	if abs(direction.x) >= abs(direction.y):
		return &"right" if direction.x > 0.0 else &"left"
	
	return &"down" if direction.y > 0.0 else &"up"
