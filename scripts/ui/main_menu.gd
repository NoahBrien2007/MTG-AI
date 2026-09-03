extends Control

@onready var btn_play: Button = $Center/VBox/BtnPlay
@onready var btn_training: Button = $Center/VBox/BtnTraining
@onready var btn_ai_stats: Button = $Center/VBox/BtnAIStats
@onready var btn_quit: Button = $Center/VBox/BtnQuit


func _ready() -> void:
	btn_play.pressed.connect(func() -> void: GameConfig.go_to(GameConfig.SCENE_DECK_SELECT))
	btn_training.pressed.connect(func() -> void: GameConfig.go_to(GameConfig.SCENE_TRAINING))
	btn_ai_stats.pressed.connect(func() -> void: GameConfig.go_to(GameConfig.SCENE_AI_STATS))
	btn_quit.pressed.connect(func() -> void: get_tree().quit())
	btn_play.grab_focus()
