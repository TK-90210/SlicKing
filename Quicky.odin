package main
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import "vendor:raylib"

// compiler flags //
STOP_ON_MISMATCHED_GENERATION_TAGS :: true
STOP_ON_POOL_OVERFLOW :: false

// Generic Data Structures //
// linked lists
// idk if a generic linked list thing is a good idea or not
// i don't need one yet so ill hold off

// Math Stuff //
Bounds :: struct {
	min: [2]f32,
	max: [2]f32,
}
Segment :: struct {
	start: [2]f32,
	end:   [2]f32,
}
similarity :: linalg.vector_dot

// Tiles //
Tile :: struct {
	color: raylib.Color,
	solid: bool,
}
TileKind :: enum u8 {
	air,
	ground,
	outside,
}
SetOfTiles :: bit_set[TileKind]
easy_tiles :: [TileKind]Tile {
	.air = {color = raylib.RAYWHITE, solid = false},
	.ground = {color = raylib.LIME, solid = true},
	.outside = {color = raylib.LIGHTGRAY, solid = true},
}

// Level //
Level :: struct {
	data: []TileKind,
	size: [2]i32,
}
level_center :: proc(level: Level) -> [2]f32 {
	return linalg.to_f32(level.size) * 0.5
}
level_bounds :: proc(level: Level) -> Bounds {
	return {min = {0, 0}, max = linalg.to_f32(level.size)}
}

CellIdx :: i64
CellPos :: [2]i32
pos_from_idx :: proc(level: Level, idx: CellIdx) -> (pos: CellPos, in_bounds: bool) {
	in_bounds = 0 <= idx && idx < i64(len(level.data)) // wait since when has this been legal???
	pos64: [2]i64
	pos64.x = (idx % i64(level.size.x))
	pos64.y = (idx - pos64.x) / i64(level.size.x)

	return linalg.to_i32(pos64), in_bounds
}
idx_from_pos :: proc(level: Level, pos: CellPos) -> (idx: CellIdx, in_bounds: bool) {
	pos64: [2]i64 = linalg.to_i64(pos)
	idx = pos64.y * i64(level.size.x) + pos64.x
	in_bounds = 0 <= pos.x && pos.x < i32(level.size.x) && 0 <= pos.y && pos.y < i32(level.size.y)
	return idx, in_bounds
}


get_tile_idx :: proc(level: Level, idx: CellIdx) -> (tile: Tile, kind: TileKind) {
	easy_tiles: [TileKind]Tile = easy_tiles
	if 0 <= idx && idx < i64(len(level.data)) {
		kind = level.data[idx]
		tile = easy_tiles[kind]
	} else {
		kind = .outside
		tile = easy_tiles[kind]
	}
	return tile, kind
}
get_tile_pos :: proc(level: Level, pos: CellPos) -> (tile: Tile, kind: TileKind) {
	idx, bounds := idx_from_pos(level, pos)
	easy_tiles: [TileKind]Tile = easy_tiles
	if bounds {
		kind = level.data[idx]
		tile = easy_tiles[kind]
	} else {
		kind = .outside
		tile = easy_tiles[kind]
	}
	return tile, kind
}
get_tile :: proc {
	get_tile_idx,
	get_tile_pos,
}

draw_level :: proc(level: Level, current_cam: Camera) {
	for idx in 0 ..< len(level.data) {
		pos, in_bouds := pos_from_idx(level, i64(idx))
		pos32: [2]f32 = linalg.to_f32(pos)
		tile, kind := get_tile(level, pos)
		rect: raylib.Rectangle = raylib.Rectangle{pos32.x, pos32.y, 1., 1.}

		raylib.DrawRectangleRec(world_to_screenspace(rect, current_cam), tile.color)
	}
}

//move_in_level(start: [2]f32, velocity: [2]f32, collision_mask: TileKind) -> 

// camera //
Camera :: struct {
	pos:  [2]f32,
	zoom: f32,
}
world_to_screenspace_vec2 :: proc(pos: [2]f32, camera: Camera) -> [2]f32 {
	screen_center: [2]f32 =
		linalg.to_f32([2]i32{raylib.GetRenderWidth(), raylib.GetRenderHeight()}) * 0.5
	center_vec: [2]f32 = screen_center - camera.pos
	return (pos - camera.pos) * camera.zoom + screen_center
}
world_to_screenspace_rect :: proc(rect: raylib.Rectangle, camera: Camera) -> raylib.Rectangle {
	pos: [2]f32 = {rect.x, rect.y}
	size: [2]f32 = {rect.width, rect.height}

	pos = world_to_screenspace_vec2(pos, camera)
	size *= camera.zoom

	return raylib.Rectangle{pos.x, pos.y, size.x, size.y}
}
world_to_screenspace :: proc {
	world_to_screenspace_vec2,
	world_to_screenspace_rect,
}

// Things //
ThingFlags :: bit_set[enum {
	does_gravity,
	move_with_mouse,
	can_go_outside_level,
	ignores_level,
}]
Thing :: struct {
	pos:        [2]f32, // 8 bytes
	velocity:   [2]f32, // 8 bytes
  size: f32,
	//on_corners: Corners,
	level:      Level, // 
	flags:      ThingFlags,
	draw_thing: proc(thing: Thing, camera: Camera),
}
nil_thing :: proc() -> Thing {
	thing: Thing = {}
	thing.draw_thing = proc(thing: Thing, camera: Camera) {}
	return thing
}
// EASY THINGS //
easy_dot :: proc(level: Level, start: [2]f32, velocity: [2]f32) -> Thing {
	thing: Thing = {
		start, // pos
		velocity, // velocity
		//calc_point_corners(level, start), // on_corners
    0, // size of a point is 0
		level, // level
		{.does_gravity}, // flags
		proc(thing: Thing, camera: Camera) {
			//raylib.DrawText(fmt.caprint(thing.pos), 400, 50, 16, raylib.BLACK)
			raylib.DrawCircleV(
				world_to_screenspace(thing.pos, camera),
				1. * camera.zoom,
				raylib.BLUE,
			)
		}, // draw_thing
	}
	//if thing.on_corners == walls[.problem_brtl] || thing.on_corners == walls[.problem_bltr] {
	//thing.on_corners += walls[.down]
	//}

	return thing
}
easy_mouse :: proc(level: Level) -> (thing: Thing) {
	thing = {
		{0, 0}, // position
		{0, 0}, // velocity
    0,
		//{}, // on corners
		level, // level
		{.move_with_mouse, .ignores_level}, // flags
		proc(thing: Thing, camera: Camera) {
			screenspace_coords: [2]f32 = world_to_screenspace(thing.pos, camera)
			raylib.DrawText(fmt.caprint(screenspace_coords), 100, 50, 16, raylib.BLACK)
			raylib.DrawCircleV(screenspace_coords, 1. * camera.zoom, raylib.RED)
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
	generations: []u32, // 4 bytes
	free:        []bool, // 1 byte
	thing:       #soa[]Thing,
}
init_things :: proc(arena: ^virtual.Arena, thing_pool: ^ThingPool, count: u32) {
	err: runtime.Allocator_Error
	thing_pool.offset = 0
	thing_pool.free, err = virtual.make(arena, []bool, count)
	thing_pool.generations, err = virtual.make(arena, []u32, count)

	thing_pool.thing, err = make(#soa[]Thing, count, virtual.arena_allocator(arena))
	assert(err == .None)
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
		thing_pool.thing[thing_idx.idx].draw_thing = thing.draw_thing
		thing_pool.thing[thing_idx.idx].velocity = thing.velocity
		thing_pool.thing[thing_idx.idx].pos = thing.pos
		thing_pool.thing[thing_idx.idx].level = thing.level
		thing_pool.thing[thing_idx.idx].flags = thing.flags
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
	} else {
		if !successful {
			return {}, successful
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
Task :: proc(
	prev_game: ^GameState,
	game_state: ^GameState,
	next_game: ^GameState,
	prev_input: InputState,
	input: InputState,
	idx: ThingIdx,
)
move_with_mouse: Task : proc(
	prev_game: ^GameState,
	game_state: ^GameState,
	next_game: ^GameState,
	prev_input: InputState,
	input: InputState,
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
			mouse_strength :: 5.
			new_thing.velocity = input.mouse_delta * mouse_strength
			//fmt.println(new_thing.pos)

			set_thing(next_things, idx, new_thing)
		}
	}
}
do_gravity: Task : proc(
	prev_game: ^GameState,
	game_state: ^GameState,
	next_game: ^GameState,
	prev_input: InputState,
	input: InputState,
	idx: ThingIdx,
) {
	things: ^ThingPool = &(game_state.things)
	next_things: ^ThingPool = &(next_game.things)
	gravity_strength :: 100.
	thing: Thing
	new_thing: Thing
	success: bool
	thing, success = get_thing(things, idx)
	new_thing, success = get_thing(next_things, idx)
	if success {
		if .does_gravity in thing.flags {
			new_thing.velocity.y = thing.velocity.y + gravity_strength * input.delta_time
		}
		set_thing(next_things, idx, new_thing)
	}
}

point_cast_tiled :: proc(level: Level, start: [2]f32, velocity: [2]f32) -> f32 {
	mag: f32 = linalg.length(velocity)
	//re: = { x: cos(rdAngle) * mag + ro.x, y: sin(rdAngle) * mag + ro.y}
	dir: [2]f32 = linalg.normalize(velocity)
	step: [2]i32 = linalg.to_i32(linalg.sign(dir))

	cell: [2]i32 = linalg.to_i32(start)

	rayUnitStepSize: [2]f32 = {
		linalg.sqrt(1 + (dir.y / dir.x) * (dir.y / dir.x)),
		linalg.sqrt(1 + (dir.x / dir.y) * (dir.x / dir.y)),
	}

	rayLength: [2]f32 = {0, 0}
	fract: [2]f32 = start - linalg.to_f32(cell)
	if (dir.x < 0) {
		rayLength.x = fract.x * rayUnitStepSize.x
	} else {
		rayLength.x = (1 - fract.x) * rayUnitStepSize.x
	}

	if (dir.y < 0) {
		rayLength.y = fract.y * rayUnitStepSize.y
	} else {
		rayLength.y = (1 - fract.y) * rayUnitStepSize.y
	}

	len: f32 = min(rayLength.x, rayLength.y)
	prev_len: f32 = 0
	collision_point: [2]f32 = start + velocity
	for ; len < mag + 1; len = min(rayLength.x, rayLength.y) {
		if _, kind := get_tile(level, cell); kind != .air {
			//rc = {ro.x + pl * rd.x, ro.y + pl * rd.y}
			break
		}

		if (rayLength.x < rayLength.y) {
			cell.x += step.x
			rayLength.x += rayUnitStepSize.x
			prev_len = len
		} else {
			cell.y += step.y
			rayLength.y += rayUnitStepSize.y
			prev_len = len
		}
	}
  prev_len = min(prev_len, mag)
	return prev_len
}

Corner :: enum u8 {
	bottom_left,
	bottom_right,
	top_right,
	top_left,
}
Corners :: bit_set[Corner]
Wall :: enum {
	none,
	down,
	up,
	right,
	left,
	all,
	problem_brtl,
	problem_bltr,
}
walls: [Wall]Corners : {
	.none = {},
	.down = {.bottom_left, .bottom_right},
	.up = {.top_left, .top_right},
	.right = {.bottom_right, .top_right},
	.left = {.bottom_left, .top_left},
	.all = {.bottom_right, .bottom_left, .top_right, .top_left},
	.problem_brtl = {.bottom_right, .top_left},
	.problem_bltr = {.top_right, .bottom_left},
}


calc_point_corners :: proc(level: Level, pos: [2]f32) -> (corners: Corners) {
	pos: [2]f32 = pos
	fract: [2]f32 = linalg.fract(pos)
	corners = walls[.none]
	if fract == {0, 0} {
		bottom_right: [2]i32 = linalg.to_i32(pos)
		bottom_left: [2]i32 = bottom_right + {-1, 0}
		top_right: [2]i32 = bottom_right + {0, -1}
		top_left: [2]i32 = bottom_right + {-1, -1}

		_, kind := get_tile(level, bottom_right)
		if kind != .air {corners += {.bottom_right}}
		_, kind = get_tile(level, bottom_left)
		if kind != .air {corners += {.bottom_left}}
		_, kind = get_tile(level, top_left)
		if kind != .air {corners += {.top_left}}
		_, kind = get_tile(level, top_right)
		if kind != .air {corners += {.top_right}}
		return corners
	}
	if fract.x == 0 {
		right: [2]i32 = linalg.to_i32(pos)
		left: [2]i32 = right + {-1, 0}
		_, kind := get_tile(level, right)
		if kind != .air {corners += walls[.right]}
		_, kind = get_tile(level, left)
		if kind != .air {corners += walls[.left]}
		return corners
	}
	if fract.y == 0 {
		down: [2]i32 = linalg.to_i32(pos)
		up: [2]i32 = down + {0, -1}
		_, kind := get_tile(level, down)
		if kind != .air {corners += walls[.down]}
		_, kind = get_tile(level, up)
		if kind != .air {corners += walls[.up]}
		return corners
	}
	return corners
}
// we'll just do this for now
calc_bump_length :: proc(thing: Thing) -> f32 {
  // for now we'll just assume that thing is a circle or point (circle with size of 0)
  return 1. - thing.size / 2
}
move: Task : proc(
	prev_game: ^GameState,
	game_state: ^GameState,
	next_game: ^GameState,
	prev_input: InputState,
	input: InputState,
	idx: ThingIdx,
) {
	things: ^ThingPool = &(game_state.things)
	next_things: ^ThingPool = &(next_game.things)
	thing: Thing
	new_thing: Thing
	success: bool
	thing, success = get_thing(things, idx)
	new_thing, success = get_thing(next_things, idx)
	if success && thing.velocity != {0, 0} {
		velocity := thing.velocity * input.delta_time
		pos: [2]f32 = thing.pos
		if .ignores_level not_in thing.flags {
			// MOVE //
			// https://youtu.be/NbSee-XM7WA?si=AUetUTj1sKyZmTBY
			len: f32 = point_cast_tiled(thing.level, pos, velocity)
			pos = pos + len
			corners: Corners = calc_point_corners(thing.level, pos)
			if corners == walls[.problem_brtl] {
				if velocity.x > 0 || velocity.y < 0 {
					corners += {.top_right}
				} else {
					corners += {.bottom_left}
				}
			}
			if corners == walls[.problem_bltr] {
				if velocity.x > 0 || velocity.y > 0 {
					corners += {.bottom_right}
				} else {
					corners += {.top_left}
				}
			}
		}
		new_thing.pos = pos + velocity
		set_thing(next_things, idx, new_thing)
	}
}
spawn_dot_on_click: Task : proc(
	prev_game: ^GameState,
	game_state: ^GameState,
	next_game: ^GameState,
	prev_input: InputState,
	input: InputState,
	idx: ThingIdx,
) {
	things: ^ThingPool = &(game_state.things)
	next_things: ^ThingPool = &(next_game.things)
	thing: Thing
	new_thing: Thing
	success: bool
	thing, success = get_thing(things, idx)
	new_thing, success = get_thing(next_things, idx)

	if .move_with_mouse in thing.flags {
		if .left_mouse in input.pressed_buttons {
			push_thing(
				next_things,
				easy_dot(
					game_state.level,
					thing.pos,
					linalg.normalize([2]f32{f32(input.random), transmute(f32)(input.random)}) * 30,
				),
			)
		}
	}
}


resolve_task :: proc(
	prev_game: ^GameState,
	game_state: ^GameState,
	next_game: ^GameState,
	prev_input: InputState,
	input: InputState,
	task: Task,
) {
	prev_things: ^ThingPool = &(prev_game.things)
	things: ^ThingPool = &(game_state.things)
	next_things: ^ThingPool = &(next_game.things)
	for i in 0 ..< things.offset {
		idx: ThingIdx = {
			idx        = i,
			generation = things.generations[i],
		}

		task(prev_game, game_state, next_game, prev_input, input, idx)
	}
}
resolve_things :: proc(
	prev_game: ^GameState,
	game_state: ^GameState,
	next_game: ^GameState,
	prev_input: InputState,
	input: InputState,
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

	resolve_task(prev_game, game_state, next_game, prev_input, input, move_with_mouse)
	resolve_task(prev_game, game_state, next_game, prev_input, input, do_gravity)
	resolve_task(prev_game, game_state, next_game, prev_input, input, move)
	resolve_task(prev_game, game_state, next_game, prev_input, input, spawn_dot_on_click)
}

// Input State
GameButton :: enum {
	left_mouse,
}
GameButtons :: bit_set[GameButton]
InputState :: struct {
	// must be smol
	delta_time:      f32, // 4 bytes
	mouse_delta:     [2]f32, // 8 bytes
	pressed_buttons: GameButtons,
	random:          u32,
}
estimate_max_runtime :: #force_inline proc(memory: int) -> (time_m: int) {
	return memory / (size_of(InputState) * 60 * 60)
}
get_input_state :: proc() -> InputState {
	pressed_buttons: GameButtons = {}
	if raylib.IsMouseButtonDown(raylib.MouseButton.LEFT) {
		pressed_buttons += {.left_mouse}
	}
	return {
		1. / 60.,
		//raylib.GetFrameTime(),
		raylib.GetMouseDelta(),
		pressed_buttons,
		rand.uint32(),
	}
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
	input: InputState,
) {
	resolve_things(prev_game, game_state, next_game, prev_input, input)
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
	raylib.DisableCursor()
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
	level.size = {200, 110}
	level.data = make([]TileKind, level.size.x * level.size.y)
	// checker
	//for tile, idx in level.data {
	//  pos, _ := pos_from_idx(level, i64(idx))
	//	level.data[idx] = TileKind((pos.x + pos.y) % 2)
	//}
	prev_game.level = level
	game_state.level = level
	next_game.level = level

	// setup camera
	camera: Camera = {
		pos  = level_center(level),
		zoom = min(
			f32(raylib.GetRenderWidth()) / f32(level.size.x),
			f32(raylib.GetRenderHeight()) / f32(level.size.y),
		) * .9,
	}
	prev_game.camera = camera
	game_state.camera = camera
	next_game.camera = camera

	// setup things
	prev_things: ThingPool = {}
	things: ThingPool = {}
	next_things: ThingPool = {}
	thing_count :: 3000
	init_things(arena, &prev_things, thing_count)
	init_things(arena, &things, thing_count)
	init_things(arena, &next_things, thing_count)
	push_thing(&prev_things, easy_dot(level, level_center(level), {-30, -30}))
	push_thing(&things, easy_dot(level, level_center(level), {-30, -30}))
	push_thing(&prev_things, easy_mouse(level))
	push_thing(&things, easy_mouse(level))
	prev_game.things = prev_things
	game_state.things = things
	next_game.things = next_things
	return prev_input, input_state, prev_game, game_state, next_game
}

main :: proc() {
	fmt.println(estimate_max_runtime(mem.Megabyte), "minutes")
	fmt.println(size_of(Thing) + 4 + 1)
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

	/*
	for !raylib.IsKeyDown(raylib.KeyboardKey.SPACE) {
		raylib.BeginDrawing()
		raylib.ClearBackground(raylib.LIGHTGRAY)
		raylib.DrawFPS(raylib.GetRenderWidth() - 100, 50)
		draw_game(game_state)
		raylib.EndDrawing()
	}
  */

	// game stuff
	for !raylib.WindowShouldClose() {
		// game loop
		// rendering (TODO) section this off into a different loop
		raylib.BeginDrawing()
		raylib.ClearBackground(raylib.LIGHTGRAY)
		raylib.DrawFPS(raylib.GetRenderWidth() - 100, 50)
		raylib.DrawText(
			fmt.caprint(game_state.things.offset),
			i32(raylib.GetRenderWidth() / 2),
			50,
			16,
			raylib.BLACK,
		)
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
