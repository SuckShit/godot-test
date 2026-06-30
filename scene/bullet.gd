extends Area2D
class_name Bullet
# 2进制位掩码，用于指定子弹与哪些物体发生碰撞
const WORLD_COLLISION_MASK := 1

# 子弹飞行速度，单位为像素/秒
@export var bullet_speed: float = 320.0
# 子弹最大存活时间，防止未命中时永久停留在场景中
@export var bullet_lifetime: float = 2.0

# 子弹当前的移动方向
var direction: Vector2 = Vector2.ZERO
# 子弹剩余存活时间，递减到0时会自动销毁子弹
var remaining_lifetime: float = 0.0
# 玩家生成子弹时的位置，用于检测子弹是否生成在地图边框外
var player_spawn_position: Vector2 = Vector2.ZERO

# 初始化寿命，并绑定Area2D的碰撞信号
func _ready() -> void:
    remaining_lifetime = bullet_lifetime
    area_entered.connect(_on_area_entered)
    # 延迟一帧检查初始位置是否在碰撞物体内部，以及是否生成在地图边框外
    call_deferred("_check_initial_collision")

# 由外部生成子弹后调用，用于注入子弹的初始移动方向和玩家位置
func setup(initial_direction: Vector2, spawn_position: Vector2 = Vector2.ZERO) -> void:
    if initial_direction != Vector2.ZERO:
        direction = initial_direction.normalized()
    else:
        push_warning("Bullet setup called with zero direction.")
    
    player_spawn_position = spawn_position

    rotation = direction.angle()

# 每帧先检测子弹飞行路径是否会与世界发生碰撞，再更新位置并处理超时回收
func _physics_process(delta: float) -> void:
    var current_position := global_position
    var new_position := current_position + direction * bullet_speed * delta

    if _will_hit_world(current_position, new_position):
        queue_free()
        return
    
    global_position = new_position
    # 没有命中，也要在超时后销毁子弹，防止无限存在
    remaining_lifetime -= delta
    if remaining_lifetime <= 0:
        queue_free()

# 检查子弹初始位置：
# 1. 是否在碰撞物体内部（点查询）
# 2. 是否生成在地图边框（SegmentShape2D）之外（从玩家位置到子弹位置的射线检测）
func _check_initial_collision() -> void:
    var space_state := get_world_2d().direct_space_state
    if space_state == null:
        return
    
    # 使用点查询检测当前位置是否在碰撞物体内部
    var query := PhysicsPointQueryParameters2D.new()
    query.position = global_position
    query.collision_mask = WORLD_COLLISION_MASK
    query.collide_with_bodies = true
    query.collide_with_areas = false
    
    var results: Array[Dictionary] = space_state.intersect_point(query)
    if not results.is_empty():
        # 子弹生成在碰撞物体内部，立即销毁
        queue_free()
        return
    
    # 如果有玩家生成位置，做射线检测：如果玩家和子弹之间有世界边框（SegmentShape2D），
    # 说明子弹生成在了地图边框之外（例如玩家贴着边界射击），立即销毁
    if player_spawn_position != Vector2.ZERO and global_position != player_spawn_position:
        if _will_hit_world(player_spawn_position, global_position):
            queue_free()

# 使用射线查询检测当前这一帧的飞行路径，避免子弹穿过零厚度边界或薄墙体
func _will_hit_world(from_position: Vector2, to_position: Vector2) -> bool:
    var space_state := get_world_2d().direct_space_state
    if space_state == null:
        return false

    var query := PhysicsRayQueryParameters2D.create(from_position, to_position, WORLD_COLLISION_MASK)
    query.collide_with_bodies = true
    query.collide_with_areas = false

    var hit_result: Dictionary = space_state.intersect_ray(query)
    return not hit_result.is_empty()

# 当子弹与其他Area2D发生碰撞后销毁，但忽略与其他子弹的碰撞
func _on_area_entered(area: Area2D) -> void:
    if area is Bullet:
        return  # Ignore collisions with other bullets

    queue_free()  # Destroy the bullet on collision with any other area