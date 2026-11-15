extends Node
## macOS port of 植物大战僵尸杂交重制版 0.31 - restores button sounds that the game data leaves
## silent on every platform (the Windows build behaves the same way).
##
## The game plays UI sounds from its C# button handlers through AudioManager.AudioPlay(). Two groups
## of buttons never make a sound:
##  1. Plain TextureButtons whose handlers never call AudioPlay: the main-menu mode buttons
##     (Adventure, Mini-games, Puzzle, Survival, ...), the level-select back arrow, the level-select
##     chapter books and level tiles (DragMenuSelectItem.OnButtonPressed only raises OnSelect, which
##     LevelChoose.Select handles without a sound), the back arrow of the award screen, and the back
##     buttons of the shop, star exchange and option dialogs.
##  2. NinePatchButtonBase buttons. Their default press sound is "ButtonClickPress", which is not an
##     entry of res://Asset/Config/Audio/AudioResource.json, so AudioPlay returns without playing.
##     The one scene that overrides it (LevelEditorOnlineLevel.tscn) uses "ButtonPress".
##
## Only the game's own sound entries are used: "ButtonPress" (identical to the original PvZ
## buttonclick.ogg) and "GraveButtonPress" (identical to the original gravebutton.ogg, already used by
## the main-menu "More modes" tombstone). Buttons that already make a sound are not touched.

const SFX := 1 # AudioManagerEnum.TYPE.SFX

# Plain buttons: owner script file -> { node path relative to the owner : sound entry }.
const PLAIN := {
	"MainMenu.cs": {
		"Background/MenuTexture/AdventureButton": "GraveButtonPress",
		"Background/MenuTexture/ChallengeButton": "GraveButtonPress",
		"Background/MenuTexture/SurvivalButton": "GraveButtonPress",
		"Background/MoreBackground/MiniGameButton": "GraveButtonPress",
		"Background/MoreBackground/PuzzleGameButton": "GraveButtonPress",
		"Background/MoreBackground/BattleGameButton": "GraveButtonPress",
		"Background/MoreBackground/IZM2GameButton": "GraveButtonPress",
		"Background/MoreBackground/StarsExchangeButton": "GraveButtonPress",
		"Background/MoreBackground/HybridParkGameButton": "GraveButtonPress",
		"Background/MenuTexture/AlmanacButton": "ButtonPress",
		"Background/MenuTexture/ShopButton": "ButtonPress",
		"Background/MenuTexture/DiyButton": "ButtonPress",
	},
	"LevelChoose.cs": {"FrontGUI/BackButton": "ButtonPress"},
	# Level-select items (instances of DragMenuSelectItem.tscn; the Button belongs to the item root).
	"DragMenuSelectItemChapter.cs": {"Graphics/Button": "ButtonPress"},
	"DragMenuSelectItemlevel.cs": {"Graphics/Button": "ButtonPress"},
	"AwardSettlement.cs": {"MoreBackButton": "ButtonPress"},
	"Shop.cs": {"CarTexture/MainMenuButton": "ButtonPress"},
	"StarExchange.cs": {"BackButton": "ButtonPress"},
	"MenuDialogBase.cs": {"Layer/Control/DialogMenu/BackButton": "GraveButtonPress"},
	"DialogMainMenuOption.cs": {"Layer/Control/DialogMenu/BackButton": "GraveButtonPress"},
	"DialogBattlePause.cs": {"Layer/Control/DialogMenu/BackButton": "GraveButtonPress"},
}

# NinePatchButtonBase instances whose handler already plays a sound (left silent on press-down).
const NINEPATCH_SKIP := {
	"Almanac.cs": ["PlantButton", "ZombieButton", "PropButton", "PropUseButton"],
	"*": ["ReSelectButton"],
}
const MISSING_DOWN_SFX := "ButtonClickPress"
const NINEPATCH_DOWN_SFX := "ButtonPress"

func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)

static func _script_file(n: Node) -> String:
	if n == null:
		return ""
	var s = n.get_script()
	return s.resource_path.get_file() if s else ""

func _on_node_added(n: Node) -> void:
	var file := _script_file(n)
	if file == "NinePatchButtonBase.cs":
		_fix_ninepatch(n)
	elif n is BaseButton and n.owner != null:
		var rules: Dictionary = PLAIN.get(_script_file(n.owner), {})
		if rules.is_empty():
			return
		var rel := str(n.owner.get_path_to(n))
		if rules.has(rel) and not n.has_meta("_mac_ui_sfx"):
			n.set_meta("_mac_ui_sfx", true)
			(n as BaseButton).pressed.connect(_play.bind(rules[rel]))

func _fix_ninepatch(n: Node) -> void:
	if str(n.get("downSfx")) != MISSING_DOWN_SFX:
		return # scene sets its own sound
	var skip: Array = NINEPATCH_SKIP.get(_script_file(n.owner), []) + NINEPATCH_SKIP["*"]
	if String(n.name) in skip:
		return
	n.set("downSfx", NINEPATCH_DOWN_SFX)

func _play(sound: String) -> void:
	var am := get_node_or_null("/root/AudioManager")
	if am != null:
		am.call("AudioPlay", sound, SFX, 0.0, true, false)
