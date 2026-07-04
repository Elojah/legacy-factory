class_name TestMap extends Node2D
## Visual rendering of the SIM collision world (WorldGeometry). Layers, back to front:
## FloorRenderer (tiling biome floors + a floating-island underside with reverse-pyramid
## stones), WaterRenderer (on-island ponds + waterfalls off the edges), MapMarkers
## (village huts + resource orbs), Foliage (swaying trees/grass/rocks). All are built
## from the SAME geometry the simulation resolves against, so the picture and collision
## stay in sync. There is no water backdrop behind the islands — they float in the sky
## (world/sky.gdshader), which shows through the gaps around them.

@onready var _floor: FloorRenderer = $FloorRenderer
@onready var _water: WaterRenderer = $Water
@onready var _markers: MapMarkers = $Markers
@onready var _foliage: Foliage = $Foliage

var _geometry: WorldGeometry

func _ready() -> void:
	if _geometry != null:
		_paint()

## Paint the map for `geometry`. Safe to call right after add_child (the node is ready
## by then) or before (deferred to _ready).
func render(geometry: WorldGeometry) -> void:
	_geometry = geometry
	if is_node_ready():
		_paint()

func _paint() -> void:
	_floor.setup(_geometry)
	_water.setup(_geometry)
	_markers.setup(_geometry)
	_foliage.setup(_geometry)

## Forwarders for the synchronized cosmetic phases, fed each frame by client_world
## (mirroring how sky.gd is fed). Water flow and wind sway derive from the GameClock,
## so every peer in the lobby sees the same motion with no extra network traffic.
func set_water_phase(p: float) -> void:
	_water.set_phase(p)

func set_wind_phase(p: float) -> void:
	_foliage.set_wind_phase(p)

## Pickup-state forwarder (orb_event → markers): hide a taken orb/cache marker
## until the server says it respawned.
func set_pickup_taken(kind: int, index: int, taken: bool) -> void:
	_markers.set_pickup_taken(kind, index, taken)
