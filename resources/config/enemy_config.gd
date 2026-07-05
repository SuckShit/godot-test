extends Resource
class_name EnemyConfig

enum Enemytype {
    BASIC,
    FAST,
    SHELLED,
    BOMBER,
}

@export_group("基础信息")
# 标记敌人大类
@export var enemy_type: Enemytype = Enemytype.BASIC
# 显示敌人名称
@export var display_name: String = "基础敌人"

@export_group("基础数值")
# 最大生命值
@export_range(1, 999, 1, "or_greater") var max_health: int = 3
# 移动速度
@export_range(0.0, 1000.0, 0.1, "or_greater") var move_speed: float = 60.0
# 碰撞半径
@export_range(1.0, 256.0, 0.5, "or_greater") var collision_radius: float = 8

@export_group("动画资源")
# 敌人本体使用的spriteframes资源
@export var enemy_frames: SpriteFrames
# 正常移动动画名
@export var move_animation_name: StringName = &"move"
# 死亡动画名
@export var death_animation_name: StringName = &"death"
# 爆炸动画名
@export var explosion_animation_name: StringName = &"explode"

@export_group("死亡效果")
# 是否在死亡时触发爆炸
@export var explode_on_death: bool = false
# 自爆伤害，只有explode_on_death为true时才生效
@export_range(0, 999, 1, "or_greater") var explosion_damage: int = 0
# 自爆半径，只有explode_on_death为true时才生效
@export_range(0.0, 512.0, 1.0, "or_greater") var explosion_radius: float = 0

@export_group("掉落")
# 掉落概率
@export_range(0.0, 1.0, 0.01, "or_greater") var pickup_drop_chance: float = 0.3
# 允许掉落的配置列表，为空时表示无掉落
@export var pickup_drop_configs: Array[PickupConfig] = [
    preload("res://resources/config/pickup_rapid.tres"),
    preload("res://resources/config/pickup_speed.tres"),
    preload("res://resources/config/pickup_spiral.tres"),
]
