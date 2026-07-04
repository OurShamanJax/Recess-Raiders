class_name BaseController
extends Node
## Base class for all controllers (spec §2.2). A controller's only job is to fill
## an Intent for its Actor each frame. PlayerController reads input, AIController
## runs role behavior, and a future NetworkController will read synced data.

var actor: Node = null
var intent: Intent = Intent.new()

func setup(p_actor: Node) -> void:
	actor = p_actor

## Override. Fill and return `intent` for this frame.
func build_intent(_delta: float) -> Intent:
	intent.clear()
	return intent
