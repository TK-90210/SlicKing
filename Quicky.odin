package main
import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:mem/virtual"
import "vendor:raylib"

// compiler flags //
STOP_ON_MISMATCHED_GENERATION_TAGS :: true
STOP_ON_POOL_OVERFLOW :: true

// Generic Data Structures //
// linked lists
// idk if a generic linked list thing is a good idea or not
// i don't need one yet so ill hold off

// Tiles //
Tile :: struct {
	color: raylib.Color,
	solid: bool,
}
TileKind :: enum u8 {
	air,
	ground,
}
fast_tiles :: [TileKind]Tile {
	.air = {color = raylib.RAYWHITE, solid = false},
	.ground = {color = raylib.LIME, solid = true},
}

// Level //
Level :: struct {
	data: []TileKind,
	size: [2]u32,
}
level_center :: proc(level: Level) -> [2]f32 {
	return linalg.to_f32(level.size) * 0.5
}

CellIdx :: u64
CellPos :: [2]u32
pos_from_idx :: proc(level: Level, idx: CellIdx) -> CellPos {
	assert(idx < u64(level.size.x * level.size.y))
	pos64: [2]u64
	pos64.x = (idx % u64(level.size.x))
	pos64.y = (idx - pos64.x) / u64(level.size.x)
	assert(pos64.x < u64(level.size.x))
	assert(pos64.y < u64(level.size.y))
	assert(pos64.x <= 0xFFFFFFFF)
	assert(pos64.y <= 0xFFFFFFFF)
	return linalg.to_u32(pos64)
}
idx_from_pos :: proc(level: Level, pos: CellPos) -> CellIdx {
	assert(pos.x < level.size.x)
	assert(pos.y < level.size.y)
	pos64: [2]u64 = [2]u64{u64(pos.x), u64(pos.y)}
	idx: CellIdx = pos64.y * u64(level.size.x) + pos64.x
	assert(idx < u64(level.size.x * level.size.y))
	return idx
}


get_tile :: proc(level: Level, pos: CellPos) -> (tile: Tile, kind: TileKind) {
	assert(pos.x < level.size.x)
	assert(pos.y < level.size.y)
	fast_tiles: [TileKind]Tile = fast_tiles

	kind = level.data[idx_from_pos(level, pos)]
	tile = fast_tiles[kind]
	return tile, kind
}

draw_level :: proc(level: Level, current_cam: Camera) {
	for idx in 0 ..< len(level.data) {
		pos: CellPos = pos_from_idx(level, u64(idx))
		pos32: [2]f32 = linalg.to_f32(pos)
		tile, kind := get_tile(level, pos)
		rect: raylib.Rectangle = raylib.Rectangle{pos32.x, pos32.y, 1., 1.}

		raylib.DrawRectangleRec(transform_to_camera(rect, current_cam), tile.color)
	}
}

// camera //
Camera :: struct {
	pos:  [2]f32,
	zoom: f32,
}
transform_vec2_to_camera :: proc(pos: [2]f32, camera: Camera) -> [2]f32 {
	screen_center: [2]f32 =
		linalg.to_f32([2]i32{raylib.GetRenderWidth(), raylib.GetRenderHeight()}) * 0.5
	center_vec: [2]f32 = screen_center - camera.pos
	return (pos - camera.pos) * camera.zoom + screen_center
}
transform_rect_to_camera :: proc(rect: raylib.Rectangle, camera: Camera) -> raylib.Rectangle {
	pos: [2]f32 = {rect.x, rect.y}
	size: [2]f32 = {rect.width, rect.height}

	pos = transform_vec2_to_camera(pos, camera)
	size *= camera.zoom

	return raylib.Rectangle{pos.x, pos.y, size.x, size.y}
}
transform_to_camera :: proc {
	transform_vec2_to_camera,
	transform_rect_to_camera,
}

// Things //
ThingFlags :: bit_set[enum {
	does_gravity,
	reset_velocity,
	move_with_mouse,
}]
Thing :: struct {
	pos:        [2]f32,
	velocity:   [2]f32,
	level:      Level,
	flags:      ThingFlags,
	draw_thing: proc(thing: Thing, camera: Camera),
}
nil_thing :: proc() -> Thing {
	thing: Thing = {}
	thing.draw_thing = proc(thing: Thing, camera: Camera) {}
	return thing
}
// FAST THINGS //
fast_dot :: proc(level: Level) -> Thing {
	thing: Thing = {
		level_center(level), // pos
		{0.4, -1.4}, // velocity
		level, // level
		{.does_gravity}, // flags
		proc(thing: Thing, camera: Camera) {
			raylib.DrawCircleV(
				transform_to_camera(thing.pos, camera),
				1. * camera.zoom,
				raylib.BLUE,
			)
		}, // draw_thing
	}

	return thing
}
fast_mouse :: proc(level: Level) -> (thing: Thing) {
	thing = {
		{0, 0},
		{0, 0},
		level,
		{.move_with_mouse, .reset_velocity},
		proc(thing: Thing, camera: Camera) {
			raylib.DrawCircleV(
				transform_to_camera(thing.pos, camera),
				1. * camera.zoom,
				raylib.RED,
			)
		}, // draw_thing
	}
	return thing
}

ThingIdx :: struct {
	idx:        u32,
	generation: u32,
}
check_idx :: proc(things: ^ThingPool, idx: ThingIdx) -> bool {
	return(
		(!things.free[idx.idx]) &&
		(idx.idx < things.offset) &&
		(idx.generation == things.generations[idx.idx]) \
	)
}
ThingPool :: struct {
	offset:      u32,
	generations: []u32,
	free:        []bool,
	thing:       #soa[]Thing,
}
init_things :: proc(arena: ^virtual.Arena, thing_pool: ^ThingPool, count: u32) {
	err: runtime.Allocator_Error
	thing_pool.offset = 0
	thing_pool.free, err = virtual.make(arena, []bool, count)
	thing_pool.generations, err = virtual.make(arena, []u32, count)
	assert(err == .None)

	pos, pos_err := virtual.make(arena, [][2]f32, count)
	assert(pos_err == .None)
	velocity, velocity_err := virtual.make(arena, [][2]f32, count)
	assert(velocity_err == .None)
	level, level_err := virtual.make(arena, []Level, count)
	assert(level_err == .None)
	draw_thing, draw_err := virtual.make(arena, []proc(thing: Thing, camera: Camera), count)
	assert(draw_err == .None)
	flags, flag_err := virtual.make(arena, []ThingFlags, count)
	assert(flag_err == .None)

	thing_pool.thing = transmute(#soa[]Thing)soa_zip(pos, velocity, level, draw_thing, flags)
}
get_thing :: proc(
	thing_pool: ^ThingPool,
	thing_idx: ThingIdx,
) -> (
	thing: Thing,
	successful: bool = true,
) {
	assert(thing_idx.idx < u32(len(thing_pool.thing)))
	generation: u32 = thing_pool.generations[thing_idx.idx]
	thing = thing_pool.thing[thing_idx.idx]
	successful = check_idx(thing_pool, thing_idx)
	return thing, successful
}
set_thing :: proc(
	thing_pool: ^ThingPool,
	thing_idx: ThingIdx,
	thing: Thing,
) -> (
	successful: bool = false,
) {
	assert(thing_idx.idx < u32(len(thing_pool.thing)))
	generation: u32 = thing_pool.generations[thing_idx.idx]
	successful = check_idx(thing_pool, thing_idx)
	if successful {
		thing_pool.thing[thing_idx.idx] = thing
	} else {
		when STOP_ON_MISMATCHED_GENERATION_TAGS {
			panic("thing is out of date")
		}
	}
	return successful
}
push_things :: proc(
	thing_pool: ^ThingPool,
	things: []Thing,
) -> (
	starting_idx: ThingIdx,
	successful: bool,
) {
	amount: u32 = u32(len(things))
	successful = thing_pool.offset + amount < u32(len(thing_pool.thing))
	when STOP_ON_POOL_OVERFLOW {
		if !successful {
			panic("pool is out of memory")
		}
	}
	starting_idx.idx = thing_pool.offset
	for i in 0 ..< amount {
		idx: u32 = i + thing_pool.offset

		thing_idx: ThingIdx = {idx, thing_pool.generations[idx] + 1}
		thing_pool.generations[idx] = thing_idx.generation

		thing_pool.offset += 1
		set_thing(thing_pool, thing_idx, things[i])
	}
	return starting_idx, successful
}
push_thing :: proc(
	thing_pool: ^ThingPool,
	thing: Thing,
) -> (
	starting_idx: ThingIdx,
	successful: bool,
) {
	things_arr: [1]Thing = {thing}
	thing_slice: []Thing = things_arr[:]
	return push_things(thing_pool, thing_slice)
}

draw_things :: proc(thing_pool: ^ThingPool, camera: Camera) {
	for i in 0 ..< thing_pool.offset {
		idx: ThingIdx = {
			idx        = i,
			generation = thing_pool.generations[i],
		}
		thing, successful := get_thing(thing_pool, idx)
		assert(successful)
		thing.draw_thing(thing, camera)
	}
}

// tasks
move_with_mouse :: proc(
	prev_game: ^GameState,
	game_state: ^GameState,
	next_game: ^GameState,
	idx: ThingIdx,
) {
	things: ^ThingPool = &(game_state.things)
	next_things: ^ThingPool = &(next_game.things)
	thing: Thing
	new_thing: Thing
	success: bool
	thing, success = get_thing(things, idx)
	new_thing, success = get_thing(next_things, idx)
	if success {
		if .move_with_mouse in thing.flags {
		}
	}
}
do_gravity :: proc(
	prev_game: ^GameState,
	game_state: ^GameState,
	next_game: ^GameState,
	idx: ThingIdx,
) {
	things: ^ThingPool = &(game_state.things)
	next_things: ^ThingPool = &(next_game.things)
	gravity_strength :: 0.05
	thing: Thing
	new_thing: Thing
	success: bool
	thing, success = get_thing(things, idx)
	new_thing, success = get_thing(next_things, idx)
	if success {
		if .does_gravity in thing.flags {
			new_thing.velocity.y = thing.velocity.y + gravity_strength
		}
		set_thing(next_things, idx, new_thing)
	}
}
move :: proc(prev_game: ^GameState, game_state: ^GameState, next_game: ^GameState, idx: ThingIdx) {
	things: ^ThingPool = &(game_state.things)
	next_things: ^ThingPool = &(next_game.things)
	thing: Thing
	new_thing: Thing
	success: bool
	thing, success = get_thing(things, idx)
	new_thing, success = get_thing(next_things, idx)
	if success {
		new_thing.pos = thing.pos + thing.velocity
		set_thing(next_things, idx, new_thing)
	}
}
reset_velocity :: proc(
	prev_game: ^GameState,
	game_state: ^GameState,
	next_game: ^GameState,
	idx: ThingIdx,
) {
	things: ^ThingPool = &(game_state.things)
	next_things: ^ThingPool = &(next_game.things)
	thing: Thing
	new_thing: Thing
	success: bool
	thing, success = get_thing(things, idx)
	new_thing, success = get_thing(next_things, idx)
	if success {
		if .reset_velocity in thing.flags {
			new_thing.velocity = {0, 0}
			set_thing(next_things, idx, new_thing)
		}
	}
}


resolve_task :: proc(
	prev_game: ^GameState,
	game_state: ^GameState,
	next_game: ^GameState,
	task: #type proc(
		prev_game: ^GameState,
		game_state: ^GameState,
		next_game: ^GameState,
		idx: ThingIdx,
	),
) {
  prev_things: ^ThingPool = &(prev_game.things)
  things: ^ThingPool = &(game_state.things)
  next_things: ^ThingPool = &(next_game.things)
	for i in 0 ..< things.offset {
		idx: ThingIdx = {
			idx        = i,
			generation = things.generations[i],
		}

		task(prev_game, game_state, next_game, idx)
	}
}
resolve_things :: proc(
	prev_game: ^GameState,
	game_state: ^GameState,
	next_game: ^GameState,
) {
	prev_things: ^ThingPool = &(prev_game.things)
	things: ^ThingPool = &(game_state.things)
	next_things: ^ThingPool = &(next_game.things)
	next_things.offset = things.offset
	for i in 0 ..< things.offset {
		idx: ThingIdx = {
			idx        = i,
			generation = things.generations[i],
		}
		next_things.generations[i] = idx.generation
		next_things.free[i] = things.free[i]

		// When game is done optimise please
		thing, success := get_thing(things, idx)
		assert(success)
		set_thing(next_things, idx, thing)
	}

	resolve_task(prev_game, game_state, next_game, move_with_mouse)
	resolve_task(prev_game, game_state, next_game, do_gravity)
	resolve_task(prev_game, game_state, next_game, move)
  resolve_task(prev_game, game_state, next_game, reset_velocity)
}

// Input State
InputState :: struct {
	// must be smol
	delta_time:     f32, // 4 bytes
	mouse_position: [2]f32, // 8 bytes
}
estimate_max_runtime :: #force_inline proc(memory: int) -> (time_m: int) {
	return memory / (size_of(InputState) * 60 * 60)
}
get_input_state :: proc() -> InputState {
	return {raylib.GetFrameTime(), raylib.GetMousePosition()}
}
// Game State
GameState :: struct {
	level:  Level,
	things: ThingPool,
	camera: Camera,
}
// Tick
tick :: proc(
	prev_game: ^GameState,
	game_state: ^GameState,
	next_game: ^GameState,
	prev_input: InputState,
	input_state: InputState,
) {
  resolve_things(prev_game, game_state, next_game)
}
// drawing
draw_game :: proc(game_state: GameState) {
	things := game_state.things
	draw_level(game_state.level, game_state.camera)
	draw_things(&things, game_state.camera)
}

// Setup //
setup_rendering :: proc() {
	raylib.SetTargetFPS(60)
	// window stuff
	monitor: i32 = raylib.GetCurrentMonitor()
	raylib.InitWindow(raylib.GetMonitorWidth(monitor), raylib.GetMonitorHeight(monitor), "Quicky")
	for !raylib.IsWindowReady() {}
	raylib.ToggleFullscreen()
	for !raylib.IsWindowFullscreen() {}
}
setup_game :: proc(
	arena: ^virtual.Arena,
) -> (
	prev_input: InputState,
	input_state: InputState,
	prev_game: GameState,
	game_state: GameState,
	next_game: GameState,
) {
	// setup input
	prev_input = {}
	input_state = {}
	// setup level
	level: Level = {}
	level.size = {201, 111}
	level.data = make([]TileKind, level.size.x * level.size.y)
	// checker
	for tile, idx in level.data {
		level.data[idx] = TileKind(
			(pos_from_idx(level, u64(idx)).x + pos_from_idx(level, u64(idx)).y) % 2,
		)
	}
	prev_game.level = level
	game_state.level = level
	next_game.level = level

	// setup camera
	camera: Camera = {
		pos  = level_center(level),
		zoom = min(
			f32(raylib.GetRenderWidth()) / f32(level.size.x),
			f32(raylib.GetRenderHeight()) / f32(level.size.y),
		),
	}
	prev_game.camera = camera
	game_state.camera = camera
	next_game.camera = camera

	// setup things
	prev_game.things = {}
	game_state.things = {}
	next_game.things = {}
	init_things(arena, &(prev_game.things), 10)
	init_things(arena, &(game_state.things), 10)
	init_things(arena, &(next_game.things), 10)
	push_thing(&prev_game.things, fast_dot(level))
	push_thing(&game_state.things, fast_dot(level))
  fmt.println(game_state.things.free[0])
  fmt.println(arena.total_used)
	push_thing(&prev_game.things, fast_mouse(level))
  fmt.println(arena.total_used)
  fmt.println(game_state.things.free[0])
	push_thing(&game_state.things, fast_mouse(level))
	return prev_input, input_state, prev_game, game_state, next_game
}

main :: proc() {
	fmt.println(estimate_max_runtime(mem.Megabyte), "minutes")
	//crash: ^virtual.Arena
	lifelong: virtual.Arena = {}
	err: runtime.Allocator_Error = {}
	err = virtual.arena_init_static(&lifelong, 1 * mem.Megabyte)
	assert(err == .None)
	scratch: virtual.Arena = {}
	err = virtual.arena_init_static(&scratch, 1 * mem.Megabyte)
	assert(err == .None)
	frame: virtual.Arena = {}
	err = virtual.arena_init_static(&frame, 1 * mem.Megabyte)
	assert(err == .None)


	setup_rendering()
	prev_input, input_state, prev_game, game_state, next_game := setup_game(&lifelong)


	// game stuff
	for !raylib.WindowShouldClose() {
		// game loop
		// rendering (TODO) section this off into a different loop
		raylib.BeginDrawing()
		raylib.ClearBackground(raylib.LIGHTGRAY)
		draw_game(game_state)
		raylib.EndDrawing()

		input_state = get_input_state()
		tick(&prev_game, &game_state, &next_game, prev_input, input_state)
    // (TODO) makes these pointers so juggling is faster
		prev_input = input_state

		//prev_prev_game: GameState = prev_game
		prev_game = game_state
		game_state = next_game
		//next_game = prev_prev_game
	}
	raylib.CloseWindow()
}
