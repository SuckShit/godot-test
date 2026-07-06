extends CharacterBody2D
class_name Enemy

const DEFAULT_BULLET_DAMAGE := 1
const BLINK_ENABLED_SHADER_PARA := &"blink_enabled"
const PICKUP_SCENE := preload("res://scene/pickup.tscn")
const EXPLOSION_QUERY_MAX_RESULTS := 16

enum DeathSequenceStage {
    NONE,
    DEATH,
    EXPLOSION,
}

# 敌人配置资源，由生成器或者编辑器指定
@export var config: EnemyConfig
# 敌人接触玩家时的伤害值
@export var touch_damage: int = 1
# 敌人持续贴住玩家时的伤害间隔
@export var touch_damage_interval: float = 0.5
# 受击闪烁持续时间
@export var hurt_blink_duration: float = 0.16

@onready var animated_sprite: AnimatedSprite2D = $AnimatedSprite2D
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var touch_damage_area: Area2D = $TouchDamageArea
@onready var touch_damage_shape: CollisionShape2D = $TouchDamageArea/CollisionShape2D
@onready var explosion_area: Area2D = $ExplosionArea
@onready var explosion_shape: CollisionShape2D = $ExplosionArea/CollisionShape2D
@onready var hit_bgm: AudioStreamPlayer = $AudioContainer/HitPlayer
@onready var die_bgm: AudioStreamPlayer = $AudioContainer/DiePlayer
@onready var explosion_bgm: AudioStreamPlayer = $AudioContainer/ExplodePlayer

# 当前追踪的玩家对象，由敌人管理器在生成时注入
var target_player: Player = null
# 当前生命值，根据配置资源初始化
var current_health: int = 1
# 敌人死亡后停止移动和受伤处理
var is_dead: bool = false
# 接触伤害冷却时间
var touch_damage_cd_left: float = 0.0
# 当前仍在接触范围的对象玩家
var touch_player: Player = null
# 受击闪烁剩余时间
var hurt_blink_time_left: float = 0.0
# 当前死亡流程所属阶段
var death_seq_stage: DeathSequenceStage = DeathSequenceStage.NONE
# 当前死亡阶段正在播放的动画名
var death_seq_animation_name: StringName = &""
# 敌人实例化自己的随机数生成，用于掉落判定
var random_generator: RandomNumberGenerator = RandomNumberGenerator.new()

# 初始化配置、信号和默认动画
func _ready() -> void:
    random_generator.randomize()
    # 检测玩家碰撞
    touch_damage_area.body_entered.connect(_on_touch_damage_area_body_entered)
    touch_damage_area.body_exited.connect(_on_touch_damage_area_body_exited)
    # 检测被子弹击中
    touch_damage_area.area_entered.connect(_on_touch_damage_area_area_entered)
    # 死亡播放动画
    animated_sprite.animation_finished.connect(_on_animated_sprite_animation_finished)
    _apply_config()

# 管理器通过统一入口注入配置和玩家引用
func setup(enemy_config: EnemyConfig, player: Player) -> void:
    config = enemy_config
    target_player = player
    _apply_config()

# 管理器单独更新追踪目标，适用于多玩家
func set_target_player(player: Player) -> void:
    target_player = player

# 子弹或其他系统通过统一接口造成伤害
func apply_damage(amount: int) -> bool:
    if is_dead:
        return false
    if amount <= 0:
        return false

    current_health -= amount

    if current_health <= 0:
        _die()
        return true
    
    _start_hurt_blink()
    _play_sfx(hit_bgm)

    return true

# 每帧处理移动，接触伤害和受击闪烁
func _physics_process(delta: float) -> void:
    _update_hurt_blink(delta)
    _update_touch_damage(delta)

    if is_dead:
        velocity = Vector2.ZERO
        return 

    if not is_instance_valid(target_player):
        velocity = Vector2.ZERO
        move_and_slide()
        return

    var move_direction := global_position.direction_to(target_player.global_position)
    _update_facing(move_direction)
    velocity = move_direction * _get_move_speed()
    move_and_slide()

# 根据配置资源刷新数值、碰撞大小和默认动画
func _apply_config() -> void:
    if config == null:
        return

    current_health = config.max_health
    _apply_collision_radius(config.collision_radius)
    _apply_explosion_radius(config.explosion_radius)

    if config.enemy_frames != null:
        animated_sprite.sprite_frames = config.enemy_frames
        if config.enemy_frames.has_animation(config.move_animation_name):
            animated_sprite.play(config.move_animation_name)
        else:
            push_warning("missing move animation: %s" % config.move_animation_name)

# 将配置中的圆形半径同步到实体碰撞和接触伤害区域
func _apply_collision_radius(radius: float) -> void:
    var body_shape := collision_shape.shape as CircleShape2D
    if body_shape != null:
        body_shape.radius = radius
    
    var damage_shape := touch_damage_shape.shape as CircleShape2D
    if damage_shape != null:
        damage_shape.radius = radius

# 将配置中的爆炸半径同步到一次爆炸检测区：
func _apply_explosion_radius(radius: float) -> void:
    var explosion_circle_shape := explosion_shape.shape as CircleShape2D
    if explosion_circle_shape != null:
        explosion_circle_shape.radius = maxf(radius, 0.0)

# 获取当前敌人移动速度
func _get_move_speed() -> float:
    if config == null:
        return 0.0

    return config.move_speed

# 根据水平移动方向决定贴图翻转，垂直移动时保持当前朝向
func _update_facing(direcion: Vector2) -> void:
    if is_zero_approx(direcion.x):
        return
    
    animated_sprite.flip_h = direcion.x < 0.0

# 接触玩家时尝试造成伤害，后续通过冷却控制伤害节奏
func _on_touch_damage_area_body_entered(body: Node2D) -> void:
    if is_dead:
        return

    var player := body as Player
    if player == null:
        return

    touch_player = player
    _try_deal_touch_damage()

# 玩家离开接触区域后，停止造成伤害
func _on_touch_damage_area_body_exited(body: Node2D) -> void:
    if body == touch_player:
        touch_player = null

# 子弹进入接触区域，对敌人造成伤害并销毁子弹
func _on_touch_damage_area_area_entered(area: Area2D) -> void:
    if is_dead:
        return

    var bullet := area as Bullet
    if bullet == null:
        return

    var damaged := apply_damage(DEFAULT_BULLET_DAMAGE)
    if damaged:
        bullet.queue_free()

# 管理与玩家接触时的伤害冷却
func _update_touch_damage(delta: float) -> void:
    if touch_damage_cd_left > 0.0:
        touch_damage_cd_left = maxf(touch_damage_cd_left - delta, 0.0)

    if touch_player == null:
        return
    if not is_instance_valid(touch_player):
        touch_player = null
        return

    if touch_damage_cd_left > 0.0:
        return

    _try_deal_touch_damage()

# 只在当前确实接触到玩家时造成伤害
func _try_deal_touch_damage() -> void:
    if touch_player == null:
        return

    touch_player.apply_damage(touch_damage)
    touch_damage_cd_left = touch_damage_interval

# 通过ShaderMaterial控制敌人短暂闪烁
func _start_hurt_blink() -> void:
    hurt_blink_time_left = hurt_blink_duration
    _set_hurt_blink_enabled(true)

# 闪烁时间结束后恢复正常显示
func _update_hurt_blink(delta: float) -> void:
    if hurt_blink_time_left <= 0.0:
        return
    
    hurt_blink_time_left = maxf(hurt_blink_time_left - delta, 0.0)
    if hurt_blink_time_left > 0.0:
        return

    _set_hurt_blink_enabled(false)

# 统一设置受击闪烁开关
func _set_hurt_blink_enabled(enabled: bool) -> void:
    var sprite_material := animated_sprite.material as ShaderMaterial
    if sprite_material != null:
        sprite_material.set_shader_parameter(BLINK_ENABLED_SHADER_PARA, enabled)

# 进入死亡后停止碰撞，并播放死亡动画
func _die() -> void:
    if is_dead:
        return

    is_dead = true
    velocity = Vector2.ZERO
    touch_player = null
    hurt_blink_time_left = 0.0
    _set_hurt_blink_enabled(false)
    collision_shape.set_deferred("disabled", true)
    touch_damage_shape.set_deferred("disabled", true)
    touch_damage_area.set_deferred("monitoring", false)
    touch_damage_area.set_deferred("monitorable", false)
    _try_drop_pickup()
    _start_death_seq()

# 先播放通用死亡动画，再根据是否爆炸播放自爆动画
func _start_death_seq() -> void:
    if config == null:
        queue_free()
        return

    _play_sfx(die_bgm)

    if _play_death_seq_animation(config.death_animation_name, DeathSequenceStage.DEATH):
        return

    _finish_after_death_animation()

# 自爆敌人进入自爆动画
func _finish_after_death_animation() -> void:
    if _should_play_explosion_seq():
        _start_explosion_seq()
        return

    queue_free()

# 自爆开始结算爆炸伤害，保证表现和逻辑同步
func _start_explosion_seq() -> void:
    if not _should_play_explosion_seq():
        queue_free()
        return

    _try_apply_explosion_damage()
    _play_sfx(explosion_bgm)

    if _play_death_seq_animation(config.explosion_animation_name, DeathSequenceStage.EXPLOSION):
        return

    queue_free()

# 统一播放死亡动画的阶段
func _play_death_seq_animation(animation_name: StringName, stage: DeathSequenceStage) -> bool:
    death_seq_stage = stage
    death_seq_animation_name = animation_name

    if config == null:
        return false
    if config.enemy_frames == null:
        return false
    if not config.enemy_frames.has_animation(animation_name):
        return false

    animated_sprite.play(animation_name)
    return true

# 只有配置中有自爆的才会播放自爆动画
func _should_play_explosion_seq() -> bool:
    return config != null and config.explode_on_death

# 自爆敌人死亡后，使用ExplosionArea的形状和掩码做碰撞检测，对其他敌人和玩家造成伤害
func _try_apply_explosion_damage() -> void:
    if config == null:
        return
    if not config.explode_on_death:
        return
    if config.explosion_damage <= 0 or config.explosion_radius <= 0.0:
        return
    if explosion_shape.shape == null:
        return

    var space_state := get_world_2d().direct_space_state
    if space_state == null:
        return
    
    var query := PhysicsShapeQueryParameters2D.new()
    query.shape = explosion_shape.shape
    query.transform = explosion_shape.global_transform
    query.collision_mask = explosion_area.collision_mask
    query.collide_with_bodies = true
    query.collide_with_areas = false
    query.exclude = [get_rid()]

    var query_results := space_state.intersect_shape(query, EXPLOSION_QUERY_MAX_RESULTS)
    if query_results.is_empty():
        return
    
    var damaged_collider_ids: Dictionary = {}

    for result in query_results:
        var collider := result.get("collider") as Node
        if collider == null:
            continue
        if collider == self:
            continue

        var collider_id := collider.get_instance_id()
        if damaged_collider_ids.has(collider_id):
            continue
        damaged_collider_ids[collider_id] = true

        var hit_player := collider as Player
        if hit_player != null:
            hit_player.apply_damage(config.explosion_damage)
            continue

        var hit_enemy := collider as Enemy
        if hit_enemy != null:
            hit_enemy.apply_damage(config.explosion_damage)

# 敌人死亡时按概率掉落道具
func _try_drop_pickup() -> void:
    if config == null:
        return
    if config.pickup_drop_configs.is_empty():
        return
    if random_generator.randf() > config.pickup_drop_chance:
        return

    var pickup_config := _pick_pickup_drop_config()
    if pickup_config == null:
        return

    call_deferred("_spawn_dropped_pickup", pickup_config, global_position)

# 从可掉落列表随机选择一个掉落
func _pick_pickup_drop_config() -> PickupConfig:
    if config == null:
        return null

    var available_pickup_configs: Array[PickupConfig] = []
    var total_weight := 0.0

    for pickup_config in config.pickup_drop_configs:
        if pickup_config == null:
            continue
        if pickup_config.drop_weight <= 0.0:
            continue
        if available_pickup_configs.has(pickup_config):
            continue

        available_pickup_configs.append(pickup_config)
        total_weight += pickup_config.drop_weight

    if available_pickup_configs.is_empty():
        return null
    if total_weight <= 0.0:
        return null
    
    var target_weight := random_generator.randf_range(0.0, total_weight)
    var accumulated_weight := 0.0

    for pickup_config in available_pickup_configs:
        accumulated_weight += pickup_config.drop_weight
        if target_weight <= accumulated_weight:
            return pickup_config

    return available_pickup_configs.back()

# 延迟到当前物理查询后在实例化掉落物，避免在碰撞回调中直接修改物理对象状态
func _spawn_dropped_pickup(pickup_config: PickupConfig, spawn_position: Vector2) -> void:
    var drop_parent := get_parent()
    if drop_parent == null:
        return

    var pickup_instance := PICKUP_SCENE.instantiate() as Pickup
    if pickup_instance == null:
        return

    pickup_instance.config = pickup_config
    drop_parent.add_child(pickup_instance)
    pickup_instance.global_position = spawn_position

# 死亡动画播放后销毁敌人实例
func _on_animated_sprite_animation_finished() -> void:
    if not is_dead:
        return
    if death_seq_animation_name == &"":
        return
    if animated_sprite.animation != death_seq_animation_name:
        return

    match death_seq_stage:
        DeathSequenceStage.DEATH:
            _finish_after_death_animation()
        DeathSequenceStage.EXPLOSION:
            queue_free()
        _:
            queue_free()

# 一次性音乐统一使用停止后再播放模式，保证重复触发时从头播放
func _play_sfx(audio: AudioStreamPlayer) -> void:
    if audio == null or audio.stream == null:
        return

    audio.stop()
    audio.play()