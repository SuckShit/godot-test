extends Node2D

const RESULT_TITLE_WIN := "你赢了"
const RESULT_TITLE_LOSE := "你输了"
const RESULT_MESSAGE_WIN := "你成功坚持到倒计时结束"
const RESULT_MESSAGE_LOSE := "玩家生命值已归零"
const RESULT_OK_BUTTON_TEXT := "游戏结束"

# 默认敌人场景和四种敌人配置
@export_group("刷怪资源")
@export var enemy_scene: PackedScene = preload("res://scene/enemy.tscn")
@export var enemy_configs: Array[EnemyConfig] = [
    preload("res://resources/config/enemy_basic.tres"),
    preload("res://resources/config/enemy_shelled.tres"),
    preload("res://resources/config/enemy_fast.tres"),
    preload("res://resources/config/enemy_explode.tres"),
]

# 刷怪节奏
@export_group("刷怪节奏")
# 开局立刻刷出的敌人数
@export_range(0, 100, 1, "or_greater") var initial_spawn_cnt: int = 1
# 每次计时器触发时生成的敌人数
@export_range(0, 20, 1, "or_greater") var spawn_cnt_per_tick: int = 1
# 开局时的刷怪间隔
@export_range(0.0, 60.0, 0.1, "or_greater") var spawn_interval: float = 1.5
# 后期最小刷新间隔
@export_range(0.0, 60.0, 0.1, "or_greater") var min_spawn_interval: float = 0.6
# 场上允许的最大敌人数
@export_range(0, 200, 1, "or_greater") var max_alive_enemies: int = 12
# # 刷怪间隔从最大到最小的时间
# @export_range(1.0, 3600.0, 1.0, "or_greater") var spawn_acc_duration: float = 60

@export_group("关卡UI")
#关卡倒计时总时长
@export_range(1.0, 3600.0, 1.0, "or_greater") var stage_duration: float = 60.0

# 主场景的核心引用
@onready var player: Player = $Player
@onready var enemy_spawn_container: Node2D = $EnemyContainer
@onready var enemy_spawn_points_root: Node2D = $EnemySpawnPoint
@onready var enemy_spawn_timer: Timer = $EnemySpawnTimer
@onready var life_count_label: Label = $HudLayer/LifeCntLabel
@onready var time_bar: Sprite2D = $HudLayer/TimeBar
@onready var result_dlg : AcceptDialog = $AcceptDialog

# 随机数生成器，用于出生位置和敌人类型配置
var random_generator: RandomNumberGenerator = RandomNumberGenerator.new()
# 缓存刷新点，避免每次刷新都遍历场景树
var enemy_spawn_points: Array[Marker2D] = []
# 缓存有效的敌人配置资源
var available_enemy_configs: Array[EnemyConfig] = []
# # 当前游戏已经运行的时间，用于增加刷怪节奏
# var game_elapsed_time: float = 0.0
# 当前关卡剩余时间倒计时秒数
var stage_time_left: float = 0.0
# 记录时间条横向缩放比例
var time_bar_full_space_x: float = 1.0
# 记录时间条左边位置
var time_bar_left_edge_x: float = 0.0
# 记录时间条原始宽度
var time_bar_width: float = 0.0
# 是否已经进入结算状态
var is_end: bool = false

# 初始化刷怪系统
func _ready() -> void:
    random_generator.randomize()
    _configure_result_dlg()
    _setup_hud()
    _collect_enemy_spawn_points()
    _collect_enemy_configs()
    _configure_enemy_spawn_timer()
    _spawn_initial_enemies()
    _start_enemy_spawn_timer()

# 每帧推进运行时间,刷新hud
func _process(delta: float) -> void:
    if is_end:
        return

    _update_stage_timer(delta)
    _update_spawn_interval()
    _update_hud()
    _check_result()

# 配置结算弹窗
func _configure_result_dlg() -> void:
    result_dlg.dialog_close_on_escape = false
    result_dlg.ok_button_text = RESULT_OK_BUTTON_TEXT
    result_dlg.hide()

    if not result_dlg.confirmed.is_connected(_on_result_dlg_exit):
        result_dlg.confirmed.connect(_on_result_dlg_exit)
    if not result_dlg.close_requested.is_connected(_on_result_dlg_exit):
        result_dlg.close_requested.connect(_on_result_dlg_exit)
    if not result_dlg.canceled.is_connected(_on_result_dlg_exit):
        result_dlg.canceled.connect(_on_result_dlg_exit)

# 初始化hud
func _setup_hud() -> void:
    stage_time_left = maxf(stage_duration, 0.0)
    time_bar_full_space_x = time_bar.scale.x
    if time_bar.texture != null:
        time_bar_width = time_bar.texture.get_width()
    if time_bar.centered:
        time_bar_left_edge_x = time_bar.position.x - time_bar_width * time_bar_full_space_x * 0.5
    else:
        time_bar_left_edge_x = time_bar.position.x

    _update_hud()

# 关卡倒计时递减
func _update_stage_timer(delta: float) -> void:
    if stage_time_left <= 0.0:
        return

    stage_time_left = maxf(stage_time_left - delta, 0.0)

# 刷新生命值和时间条
func _update_hud() -> void:
    _update_life_cnt_label()
    _update_time_bar()

# 生命值显示为‘X N’形式
func _update_life_cnt_label() -> void:
    life_count_label.text = "X %d" % _get_player_current_health()

# 按倒计时百分比缩放时间条
func _update_time_bar() -> void:
    var fill_ratio := 0.0
    if stage_duration > 0.0:
        fill_ratio = clamp(stage_time_left / stage_duration, 0.0, 1.0)

    time_bar.scale.x = time_bar_full_space_x * fill_ratio

    if not time_bar.centered:
        time_bar.position.x = time_bar_left_edge_x
        return

    var current_width := time_bar_width * time_bar.scale.x
    time_bar.position.x = time_bar_left_edge_x + (current_width * 0.5)

# 判断触发终局结算
func _check_result() -> void:
    if stage_time_left <= 0.0:
        _show_result_dlg(RESULT_TITLE_WIN, RESULT_MESSAGE_WIN)
    
    if _get_player_current_health() <= 0:
        _show_result_dlg(RESULT_TITLE_LOSE, RESULT_MESSAGE_LOSE)

# 弹出结算窗口前砸瓦鲁多，将焦点交给确定按钮
func _show_result_dlg(title: String, msg: String) -> void:
    if is_end:
        return

    is_end = true
    result_dlg.title = title
    result_dlg.dialog_text = msg
    _stop_world()
    result_dlg.popup_centered()

    var ok_btn := result_dlg.get_ok_button()
    if ok_btn != null:
        ok_btn.grab_focus()

# 停止刷怪，暂停场景树
func _stop_world() -> void:
    enemy_spawn_timer.stop()
    Engine.time_scale = 0.0
    get_tree().paused = true

# 结束游戏
func _on_result_dlg_exit() -> void:
    get_tree().quit()

# 获取玩家当前生命值
func _get_player_current_health() -> int:
    return player.get_current_health()

# 从EnemySpawnPoint下收集所有Marker2D
func _collect_enemy_spawn_points() -> void:
    enemy_spawn_points.clear()

    for child in enemy_spawn_points_root.get_children():
        var spawn_point := child as Marker2D
        if spawn_point != null:
            enemy_spawn_points.append(spawn_point)

    if enemy_spawn_points.is_empty():
        push_warning("空的EnemySpawnPoint节点")

# 缓存有效的敌人配置
func _collect_enemy_configs() -> void:
    available_enemy_configs.clear()

    for enemy_config in enemy_configs:
        if enemy_config != null:
            available_enemy_configs.append(enemy_config)

    if available_enemy_configs.is_empty():
        push_warning("空的敌人配置EnemyConfig")

# 统一配置主场景中的刷怪计时器
func _configure_enemy_spawn_timer() -> void:
    enemy_spawn_timer.one_shot = false
    enemy_spawn_timer.wait_time = _get_current_spawn_interval()

    if not enemy_spawn_timer.timeout.is_connected(_on_enemy_spawn_timer_timeout):
        enemy_spawn_timer.timeout.connect(_on_enemy_spawn_timer_timeout)

# 缩短刷怪间隔加快速度
func _update_spawn_interval() -> void:
    var current_interval = _get_current_spawn_interval()
    if is_equal_approx(current_interval, enemy_spawn_timer.wait_time):
        return

    enemy_spawn_timer.wait_time = current_interval

    # 如果当前这一轮倒计时比新的间隔长，立刻切换到更快的节奏
    if enemy_spawn_timer.is_stopped():
        return
    if enemy_spawn_timer.time_left <= current_interval:
        return

    enemy_spawn_timer.start(current_interval)

# 通过游戏时间计算刷怪间隔
func _get_current_spawn_interval() -> float:
    var start_interval = maxf(spawn_interval, 0.1)
    var end_interval = minf(maxf(min_spawn_interval, 0.1), start_interval)

    if stage_duration <= 0.0:
        return end_interval

    var difficulty_ratio := clampf(stage_time_left / stage_duration, 0.0, 1.0)
    return lerpf(start_interval, end_interval, difficulty_ratio)

# 开局立刻刷新一些敌人
func _spawn_initial_enemies() -> void:
    for _index in range(initial_spawn_cnt):
        if not _try_spawn_enemy():
            break

# 当前刷怪系统准备完成后再启动定时器
func _start_enemy_spawn_timer() -> void:
    if not _is_spawn_enemy_ready():
        return

    enemy_spawn_timer.start()

# 每次计时器触发时，按设定数量尝试刷新敌人
func _on_enemy_spawn_timer_timeout() -> void:
    for index in range(spawn_cnt_per_tick):
        if not _try_spawn_enemy():
            break

# 刷新敌人
func _try_spawn_enemy() -> bool:
    if not _is_spawn_enemy_ready():
        return false
    if _get_alive_enemy_cnt() >= max_alive_enemies:
        return false

    var spawn_point := _pick_spawn_point()
    if spawn_point == null:
        return false

    var enemy_config := _pick_enemy_config()
    if enemy_config == null:
        return false

    var enemy_inst := enemy_scene.instantiate() as Enemy
    if enemy_inst == null:
        return false

    enemy_spawn_container.add_child(enemy_inst)
    enemy_inst.global_position = spawn_point.global_position
    enemy_inst.setup(enemy_config, player)

    return true

# 只要条件有效就刷怪
func _is_spawn_enemy_ready() -> bool:
    return (
        player != null
        and enemy_scene != null
        and not enemy_spawn_points.is_empty()
        and not available_enemy_configs.is_empty()
    )

# 挑选出生点
func _pick_spawn_point() -> Marker2D:
    if enemy_spawn_points.is_empty():
        return null

    var index = random_generator.randi_range(0, enemy_spawn_points.size() - 1)
    return enemy_spawn_points[index]

# 挑选敌人配置
func _pick_enemy_config() -> EnemyConfig:
    if available_enemy_configs.is_empty():
        return null

    var index = random_generator.randi_range(0, available_enemy_configs.size() - 1)
    return available_enemy_configs[index]

# 统计当前或者的敌人，避免将敌人掉落的道具也挂载节点下导致统计在内
func _get_alive_enemy_cnt() -> int:
    var alive_cnt := 0

    for child in enemy_spawn_container.get_children():
        if child is Enemy:
            alive_cnt += 1

    return alive_cnt