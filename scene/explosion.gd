extends Node2D
class_name Explosion
# 纯代码粒子爆炸效果，不需要任何外部贴图资源
# 子弹销毁时生成多个小圆点向四周飞散并淡出

const PARTICLE_COUNT := 12       # 粒子数量
const DURATION := 0.35           # 爆炸持续秒数
const MAX_SPEED := 90.0          # 最远飞散距离（像素/秒）
const MAX_SIZE := 3.5            # 最大粒子半径（像素）
const COLOR_START := Color(1.0, 0.85, 0.3, 1.0)   # 起始色：亮黄
const COLOR_END := Color(1.0, 0.3, 0.1, 0.0)      # 结束色：红透明

# 粒子数据结构
var _particles: Array[Dictionary] = []
var _elapsed: float = 0.0

func _ready() -> void:
	# 生成随机粒子
	for i in range(PARTICLE_COUNT):
		var angle := randf_range(0.0, TAU)
		var speed := randf_range(MAX_SPEED * 0.3, MAX_SPEED)
		_particles.append({
			"angle": angle,
			"speed": speed,
			"size": randf_range(MAX_SIZE * 0.4, MAX_SIZE),
			"offset": Vector2(randf_range(-2.0, 2.0), randf_range(-2.0, 2.0)),
		})

# 自动销毁
func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= DURATION:
		queue_free()
		return
	queue_redraw()

# 绘制粒子（每帧重新绘制）
func _draw() -> void:
	if _elapsed <= 0.0 or _elapsed >= DURATION:
		return

	var progress := _elapsed / DURATION  # 0→1

	for p in _particles:
		var distance: float = p["speed"] * _elapsed
		var pos: Vector2 = p["offset"] + Vector2(
			cos(p["angle"]), sin(p["angle"])
		) * distance

		var size: float = p["size"] * (1.0 - progress * 0.7)
		var color: Color = COLOR_START.lerp(COLOR_END, progress)
		var rand_sz: float = max(size, 0.5)
		draw_rect(Rect2(pos - Vector2(rand_sz, rand_sz), Vector2(rand_sz * 2, rand_sz * 2)), color)
