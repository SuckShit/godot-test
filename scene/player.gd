extends CharacterBody2D
class_name Player

const NORMAL_ANIMATION_PREFIX := &"normal"

const BULLET_SCENE := preload("res://scene/bullet.tscn")
const ARMED_ANIMATION_PREFIX := &"armed"

const DEFAULT_MOVE_SPEED_MULTIPLIER := 1.0
const DEFAULT_FIRE_RATE_MULTIPLIER := 1.0
const SPIRAL_PHASE_STEP := PI / 12
const BLINK_ENABLED_SHADER_PARA := &"blink_enabled"
const WORLD_COLLISION_MASK := 1

# 角色动画节点，负责播放四方向移动动画
@onready var body_sprite: AnimatedSprite2D = $BodySprite
# 强化形态下显示的浮游炮特效
@onready var armed_effect_sprite: AnimatedSprite2D = $ArmedEffSprite
# 射击计时器，只负责限制开火频率
@onready var shooting_timer: Timer = $ShootingTimer
@onready var shooting_player: AudioStreamPlayer = $AudioContainer/ShootPlayer
@onready var move_player: AudioStreamPlayer = $AudioContainer/MovePlayer
@onready var pickup_player: AudioStreamPlayer = $AudioContainer/PickupPlayer

# 当前朝向后缀
var facing_suffix: StringName = &"right"

# 当前移速倍率，由道具效果决定
var current_move_speed_multiplier: float = DEFAULT_MOVE_SPEED_MULTIPLIER
# 普通射速道具提供的射速倍率
var rapid_fire_rate_multiplier: float = DEFAULT_FIRE_RATE_MULTIPLIER
# 形态道具提供的专属射速倍率
var form_fire_rate_multiplier: float = DEFAULT_FIRE_RATE_MULTIPLIER
# 当前玩家形态，决定用normal还是armed动画
var current_form_mode: int = PickupConfig.PlayerFormMode.NORMAL
# 当前弹幕模式，决定普通还是螺旋弹幕
var current_shot_pattern: int = PickupConfig.ShotPattern.NORMAL
# 三类buff分别维护各自持续时间
var speed_buff_time_left: float = 0.0
var rapid_buff_time_left: float = 0.0
var form_buff_time_left: float = 0.0
# 螺旋弹幕的相位
var spiral_phase: float = 0.0

# 玩家移动速度，单位像素/秒
@export var move_speed: float = 120.0
# 玩家最大生命值
@export var max_health: int = 5
# 玩家受伤进入无敌闪烁持续时间
@export var immune_duration: float = 1.0

# 玩家当前生命值
var current_health: int = 0
# 无敌闪烁剩余时间
var immune_time_left: float = 0.0
# 是否死亡
var is_dead: bool = false

# 玩家开火间隔，单位秒，越小开火越快
@export var fire_interval: float = 0.18
# 玩家子弹生成距离，单位像素，避免子弹出生在玩家身体内部
@export var bullet_spawn_distance: float = 18.0

func _ready() -> void:
	current_health = maxi(max_health, 1)
	shooting_timer.one_shot = true
	shooting_timer.wait_time = _get_effective_fire_interval()
	_set_hurt_blink_enabled(false)
	_update_animation()
	_update_armed_effect()

func _physics_process(_delta: float) -> void:
	_update_immune(_delta)
	_update_pickup_effects(_delta)

	if is_dead:
		velocity = Vector2.ZERO
		_set_move_sfx_active(false)
		return

	# 读取四个方向的输入，并得到标准化后的八向输入向量
	var move_input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var shot_input := Input.get_vector("shot_left", "shot_right", "shot_up", "shot_down")
	var is_moving := move_input != Vector2.ZERO

	# CharacterBody2D的velocity属性用于控制移动速度，move_and_slide()方法会根据当前速度和碰撞信息更新位置
	velocity = move_input * _get_effective_move_speed()
	move_and_slide()
	_set_move_sfx_active(is_moving)

	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
		_try_auto_shoot_spiral()
	elif shot_input != Vector2.ZERO:
		_try_shoot(shot_input)

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
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
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
		_play_sfx(shooting_player)
	shooting_timer.start(_get_effective_fire_interval())

# 道具统一通过这个入口影响玩家，Pickup场景不直接修改玩家内部细节
func apply_pickup(config: PickupConfig) -> bool:
	if config == null:
		return false
	
	var applied := false
	var should_refresh_shooting_timer := false
	var buff_duration := maxf(config.duration, 0.0)
	var has_form_override := (
		config.player_form_mode != PickupConfig.PlayerFormMode.NORMAL
		or config.shot_pattern != PickupConfig.ShotPattern.NORMAL
	)
	var has_fire_rate_override := not is_equal_approx(
		config.fire_rate_multiplier,
		DEFAULT_FIRE_RATE_MULTIPLIER
	)

	if not is_equal_approx(config.move_speed_multiplier, DEFAULT_MOVE_SPEED_MULTIPLIER):
		current_move_speed_multiplier = config.move_speed_multiplier
		speed_buff_time_left = buff_duration
		applied = true
	
	# 普通射速和专属形态射速拆开维护，避免螺旋形态的射速被其他buff覆盖
	if has_fire_rate_override and not has_form_override:
		rapid_fire_rate_multiplier = config.fire_rate_multiplier
		rapid_buff_time_left = buff_duration
		should_refresh_shooting_timer = true
		applied = true

	if has_form_override:
		current_form_mode = config.player_form_mode
		current_shot_pattern = config.shot_pattern
		form_fire_rate_multiplier = (
			config.fire_rate_multiplier if has_fire_rate_override else DEFAULT_FIRE_RATE_MULTIPLIER
		)
		form_buff_time_left = buff_duration
		spiral_phase = 0.0
		should_refresh_shooting_timer = true
		applied = true
	
	if should_refresh_shooting_timer:
		_refresh_shooting_timer_wait_time()
	if applied:
		_play_sfx(pickup_player)

	return applied

# 玩家受到伤害
func apply_damage(amount: int) -> bool:
	if is_dead:
		return false
	if amount <= 0:
		return false
	if immune_time_left > 0.0:
		return false

	current_health = maxi(current_health - amount, 0)
	if current_health <= 0:
		_die()
		return true

	_start_immune()
	return true

func get_current_health() -> int:
	return current_health

# 根据当前弹幕形式决定发射方式，螺旋弹幕会同时发射两个相反方向的子弹，最终返回是否至少有一个子弹成功生成
func _fire_bullet(direction: Vector2) -> bool:
	if current_shot_pattern == PickupConfig.ShotPattern.SPIRAL:
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
	bullet.setup(direction, global_position)
	# 子弹挂载当前场景下，避免跟随玩家节点移动
	var spawn_parrent := get_tree().current_scene
	if spawn_parrent == null:
		return false

	spawn_parrent.add_child(bullet)
	bullet.global_position = global_position + direction * bullet_spawn_distance

	if not _can_spawn_bullet(direction):
		bullet._explode()
		return false

	return true

func _can_spawn_bullet(direction: Vector2) -> bool:
	var spawn_position := global_position + direction * bullet_spawn_distance
	var space_state := get_world_2d().direct_space_state
	if space_state == null:
		return true
    
	# 使用点查询检测当前位置是否在碰撞物体内部
	var query := PhysicsRayQueryParameters2D.create(
		global_position,
		spawn_position,
		WORLD_COLLISION_MASK,
	)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [get_rid()]

	var results: Dictionary = space_state.intersect_ray(query)
	return results.is_empty()

# 螺旋形态下自动按照固定间隔朝360度旋转的方向发射子弹，形成螺旋弹幕效果
func _try_auto_shoot_spiral() -> void:
	if not shooting_timer.is_stopped():
		return

	var spiral_direction := Vector2.RIGHT.rotated(spiral_phase)
	var is_spawned_bullet := _fire_bullet(spiral_direction)
	if is_spawned_bullet:
		_play_sfx(shooting_player)
	shooting_timer.start(_get_effective_fire_interval())

# 每帧跟新道具buff剩余时间，并在到期后恢复默认
func _update_pickup_effects(delta: float) -> void:
	if speed_buff_time_left > 0.0:
		speed_buff_time_left = maxf(speed_buff_time_left - delta, 0.0)
		if speed_buff_time_left <= 0.0:
			current_move_speed_multiplier = DEFAULT_MOVE_SPEED_MULTIPLIER

	if rapid_buff_time_left > 0.0:
		rapid_buff_time_left = maxf(rapid_buff_time_left - delta, 0.0)
		if rapid_buff_time_left <= 0.0:
			rapid_fire_rate_multiplier = DEFAULT_FIRE_RATE_MULTIPLIER
			_refresh_shooting_timer_wait_time()

	if form_buff_time_left > 0.0:
		form_buff_time_left = maxf(form_buff_time_left - delta, 0.0)
		if form_buff_time_left <= 0.0:
			current_form_mode = PickupConfig.PlayerFormMode.NORMAL
			current_shot_pattern = PickupConfig.ShotPattern.NORMAL
			form_fire_rate_multiplier = DEFAULT_FIRE_RATE_MULTIPLIER
			spiral_phase = 0.0
			_refresh_shooting_timer_wait_time()

# 更新无敌时间
func _update_immune(delta: float) -> void:
	if immune_time_left <= 0.0:
		return
	
	immune_time_left = maxf(immune_time_left - delta, 0.0)
	if immune_time_left > 0.0:
		return

	_set_hurt_blink_enabled(false)

func _get_effective_move_speed() -> float:
	return move_speed * current_move_speed_multiplier

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
		current_form_mode != PickupConfig.PlayerFormMode.NORMAL 
		or current_shot_pattern != PickupConfig.ShotPattern.NORMAL
	)

# 统一刷新射击计时器的基础间隔，避免buff生效后仍然使用旧数值
func _refresh_shooting_timer_wait_time() -> void:
	var new_interval := _get_effective_fire_interval()
	shooting_timer.wait_time = new_interval

	# 如果玩家在射击CD过程中拾取了射速buff，需要降低当次射速CD
	if shooting_timer.is_stopped():
		return
	if shooting_timer.time_left <= new_interval:
		return

	shooting_timer.start(new_interval)

# 开启玩家受伤后无敌闪烁
func _start_immune() -> void:
	immune_time_left = maxf(immune_duration, 0.0)
	_set_hurt_blink_enabled(true)

# 玩家受伤闪烁开关
func _set_hurt_blink_enabled(enabled: bool) -> void:
	var sprite_material = body_sprite.material as ShaderMaterial
	if sprite_material != null:
		sprite_material.set_shader_parameter(BLINK_ENABLED_SHADER_PARA, enabled)

# 玩家挂了
func _die() -> void:
	is_dead = true
	velocity = Vector2.ZERO
	immune_time_left = 0.0
	_set_hurt_blink_enabled(false)
	shooting_timer.stop()
	_set_move_sfx_active(false)
	armed_effect_sprite.visible = false
	armed_effect_sprite.stop()
	body_sprite.play("death")
	# 等待死亡动画播放完毕后再隐藏
	if not body_sprite.animation_finished.is_connected(_on_death_animation_finished):
		body_sprite.animation_finished.connect(_on_death_animation_finished)

# 根据当前形态选择动画前缀
func _get_animation_prefix() -> StringName:
	if current_form_mode == PickupConfig.PlayerFormMode.ARMED:
		return ARMED_ANIMATION_PREFIX
	
	return NORMAL_ANIMATION_PREFIX

# 死亡动画播放完毕后的回调
func _on_death_animation_finished() -> void:
	if body_sprite.animation == "death":
		body_sprite.stop()
		body_sprite.visible = false
		# 断开连接，避免重复触发
		if body_sprite.animation_finished.is_connected(_on_death_animation_finished):
			body_sprite.animation_finished.disconnect(_on_death_animation_finished)

# 强化螺旋形态下显示浮游炮动画，结束后隐藏并停止播放
func _update_armed_effect() -> void:
	var is_armed := current_form_mode == PickupConfig.PlayerFormMode.ARMED

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

# 主场景结束时统一结束所有运行时玩家音乐播放
func stop_runtime_audio() -> void:
	_set_move_sfx_active(false)
	if shooting_player != null and shooting_player.playing:
		shooting_player.stop()
	if pickup_player != null and pickup_player.playing:
		pickup_player.stop()

# 根据移动状态启停音效
func _set_move_sfx_active(active: bool) -> void:
	if move_player == null or move_player.stream == null:
		return

	if active:
		if not move_player.playing:
			move_player.play()
		return

	if move_player.playing:
		move_player.stop()

# 一次性音乐统一使用停止后再播放模式，保证重复触发时从头播放
func _play_sfx(audio: AudioStreamPlayer) -> void:
	if audio == null or audio.stream == null:
		return

	audio.stop()
	audio.play()

# 将任意二维向量映射为四个方向的后缀，用于选择动画
func _vector_to_facing_suffix(direction: Vector2) -> StringName:		
	if abs(direction.x) >= abs(direction.y):
		return &"right" if direction.x > 0.0 else &"left"
	
	return &"down" if direction.y > 0.0 else &"up"
