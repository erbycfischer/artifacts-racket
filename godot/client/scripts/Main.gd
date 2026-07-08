extends Node3D

const TILE_SIZE := 1.0
const SAMPLE_TILES := [
	{"x": -1, "y": 0, "layer": "overworld", "skin": "forest"},
	{"x": 0, "y": 0, "layer": "overworld", "skin": "bank"},
	{"x": 1, "y": 0, "layer": "overworld", "skin": "forest"},
	{"x": 0, "y": 1, "layer": "overworld", "skin": "grand_exchange"},
]

@onready var world_root: Node3D = $WorldRoot

func _ready() -> void:
	_build_sample_world()

func _build_sample_world() -> void:
	for tile in SAMPLE_TILES:
		var mesh := MeshInstance3D.new()
		mesh.name = "Tile_%s_%s_%s" % [tile["layer"], tile["x"], tile["y"]]
		mesh.mesh = BoxMesh.new()
		mesh.position = Vector3(tile["x"] * TILE_SIZE, 0.0, tile["y"] * TILE_SIZE)
		mesh.scale = Vector3(0.95, 0.08, 0.95)
		mesh.material_override = _material_for_skin(tile["skin"])
		world_root.add_child(mesh)

func _material_for_skin(skin: String) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	match skin:
		"bank":
			material.albedo_color = Color(0.3, 0.45, 0.95)
		"grand_exchange":
			material.albedo_color = Color(0.95, 0.72, 0.22)
		_:
			material.albedo_color = Color(0.18, 0.55, 0.24)
	return material
