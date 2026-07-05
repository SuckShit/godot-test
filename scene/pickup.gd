extends Area2D
class_name Pickup

const BLINK_ENABLED_SHADER_PARA = &"blink_enabled"

# 当前掉落物使用的资源配置
@export var config: PickupConfig
# 道具在消失前多久可以闪烁
@export_range(0.0, 10.0, 0.1, "or_greater") var blink_before_expire: float = 1.2

@onready var sprite: Sprite2D = $Sprite2D
@onready var life_timer: Timer = $LifeTimer

# 闪烁一旦开启就持续到道具消失
var is_expiring: bool = false

# 初始化显示图标、寿命计时和拾取检测
func _ready() -> void:
    body_entered.connect(_on_body_entered)
    life_timer.timeout.connect(_on_life_timer_timeout)
    life_timer.one_shot = true
    if life_timer.wait_time > 0.0:
        life_timer.start()
    _set_blink_enabled(false)
    _apply_config_to_visual()

# 道具临近消失时闪烁提示
func _process(_delta: float) -> void:
    if is_expiring:
        return
    if life_timer.is_stopped():
        return
    if life_timer.time_left > blink_before_expire:
        return

    is_expiring = true
    _set_blink_enabled(true)

# 将配置中的图标资源应用到显示节点上
func _apply_config_to_visual() -> void:
    if config == null:
        push_warning("Pickup Config is missing")
        return
    
    sprite.texture = config.icon_texture

# 玩家进入后，将配置统一交由玩家处理，是否应用buff由玩家决定
func _on_body_entered(body: Node2D) -> void:
    if config == null:
        return
    
    var player := body as Player
    if player == null:
        return

    if player.apply_pickup(config):
        queue_free()

# 道具寿命结束后消失
func _on_life_timer_timeout() -> void:
    queue_free()

# 统一控制道具是否应用闪烁效果
func _set_blink_enabled(enabled: bool) -> void:
    var sprite_material := sprite.material as ShaderMaterial
    if sprite_material != null:
        sprite_material.set_shader_parameter(BLINK_ENABLED_SHADER_PARA, enabled)