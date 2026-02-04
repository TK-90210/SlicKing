package main
import "base:runtime"
import "core:container/intrusive/list"
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

// Globals //
global_scratch_arena: virtual.Arena = {}
get_scratch :: proc() -> virtual.Arena_Temp {
	return virtual.arena_temp_begin(&global_scratch_arena)
}

// Generic Data Structures //
// linked lists
ThingNode :: struct {
	thing: ThingIdx,
	link:  list.Node,
}


// idk if a generic linked list thing is a good idea or not
// i don't need one yet so ill hold off

// Math Stuff //
// i can play around with different mass densities if i want
// aparently water is 1 gram per cubic centimeter and air is 1/800 of water
drag_force :: proc(
	fluid_mass_density: f32 = 1. / 1600.,
	flow_velocity: [2]f32,
	drag_coefficient: f32,
	reference_area: f32 = 1.0,
) -> (
	drag_force: f32,
) {
	return(
		0.5 *
		fluid_mass_density *
		linalg.length(flow_velocity) *
		linalg.length(flow_velocity) *
		drag_coefficient *
		reference_area \
	)
}
Bounds :: struct {
	min: [2]f32,
	max: [2]f32,
}
Segment :: struct {
	start: [2]f32,
	end:   [2]f32,
}
similarity :: linalg.vector_dot
// we'll just do this for now
Wall :: enum {
	north,
	east,
	south,
	west,
}
Walls :: bit_set[Wall]
point_cast_tiled :: proc(
	level: Level,
	start: [2]f32,
	velocity: [2]f32,
) -> (
	length: f32,
	hit: Walls,
) {
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

	possible_walls: [2]Wall = {.west if step.x < 0 else .east, .north if step.y < 0 else .south}
	len: f32 = rayLength.y
	possible_hit: Walls = {possible_walls.y}
	if rayLength.x < rayLength.y {
		len = rayLength.x
		possible_hit = {possible_walls.x}
	}
	len = min(len, mag)
	prev_len: f32 = 0
	hit = {}
	for ; len < mag + 1; len = min(rayLength.x, rayLength.y) {
		if tile, kind := get_tile(level, cell); tile.solid {
			//rc = {ro.x + pl * rd.x, ro.y + pl * rd.y}
			hit = possible_hit
			break
		}

		if (rayLength.x < rayLength.y) {
			cell.x += step.x
			rayLength.x += rayUnitStepSize.x
			prev_len = len
			possible_hit = {possible_walls.x}

		} else {
			cell.y += step.y
			rayLength.y += rayUnitStepSize.y
			prev_len = len
			possible_hit = {possible_walls.y}
		}
	}
	prev_len = min(prev_len, mag)
	length = mag
	if hit != {} {
		length = prev_len
	}
	return length, hit
}
bump_point_away_from_walls :: proc(
	level: Level,
	pos: [2]f32,
	bump_radius: f32,
) -> (
	out_pos: [2]f32,
) {
	out_pos = pos
	cell: CellPos = linalg.to_i32(pos)
	fract: [2]f32 = linalg.fract(pos)
	wall_dirs :: enum {
		north,
		east,
		south,
		west,
	}
	wall_cells: [wall_dirs][2]i32 = {
		.north = {0, -1},
		.east  = {1, 0},
		.south = {0, 1},
		.west  = {-1, 0},
	}
	wall_points: [wall_dirs][2]f32 = {
		.north = {fract.x, 0.},
		.east  = {1, fract.y},
		.south = {fract.x, 1},
		.west  = {0, fract.y},
	}

	corner_dirs :: enum {
		north_west,
		north_east,
		south_east,
		south_west,
	}
	corner_cells: [corner_dirs][2]i32 = {
		.north_west = {-1, -1},
		.north_east = {1, -1},
		.south_east = {1, 1},
		.south_west = {-1, 1},
	}
	corner_points: [corner_dirs][2]f32 = {
		.north_west = {0, 0},
		.north_east = {1, 0},
		.south_east = {1, 1},
		.south_west = {0, 1},
	}


	wall_bump: [2]f32 = {0, 0}
	for wall in wall_dirs {
		if tile, kind := get_tile_pos(level, cell + wall_cells[wall]); tile.solid {
			wall_point_to_fract: [2]f32 = fract - wall_points[wall]
			len: f32 = max(bump_radius - linalg.length(wall_point_to_fract), 0)
			dir: [2]f32 = linalg.normalize(wall_point_to_fract)
			wall_bump += len * dir
		}
	}
	out_pos += wall_bump


	cell = linalg.to_i32(out_pos)
	fract = linalg.fract(out_pos)

	corner_bump: [2]f32 = {0, 0}
	for corner in corner_dirs {
		if tile, kind := get_tile_pos(level, cell + corner_cells[corner]); tile.solid {
			corner_point_to_fract: [2]f32 = fract - corner_points[corner]
			len: f32 = max(bump_radius - linalg.length(corner_point_to_fract), 0)
			dir: [2]f32 = linalg.normalize(corner_point_to_fract)
			corner_bump += len * dir
		}
	}

	out_pos += corner_bump
	return out_pos
}

// Tiles //
Tile :: struct {
	color:    raylib.Color,
	solid:    bool,
	friction: f32,
}
TileKind :: enum u8 {
	snow,
	dirt,
	ice,
	water,
	wall,
	outside,
}
SetOfTiles :: bit_set[TileKind]
easy_tiles :: [TileKind]Tile {
	.dirt = {color = raylib.BROWN, solid = false, friction = 1.5},
	.snow = {color = raylib.RAYWHITE, solid = false, friction = 1.0},
	.ice = {color = raylib.SKYBLUE, solid = false, friction = 0.2},
	.water = {color = raylib.BLUE, solid = false, friction = 0.6},
	.wall = {color = raylib.DARKPURPLE, solid = true, friction = 1.0},
	.outside = {color = raylib.LIGHTGRAY, solid = true, friction = 1.0},
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
set_tile_idx :: proc(level: Level, idx: CellIdx, kind: TileKind) {
	if 0 <= idx && idx < i64(len(level.data)) {
		level.data[idx] = kind
	}
}
set_tile_pos :: proc(level: Level, pos: CellPos, kind: TileKind) {
	idx, bounds := idx_from_pos(level, pos)
	if bounds {
		level.data[idx] = kind
	}
}
set_tile :: proc {
	set_tile_idx,
	set_tile_pos,
}

draw_level :: proc(things: ^ThingPool, level: Level, current_cam: ThingIdx) {
	for idx in 0 ..< len(level.data) {
		pos, in_bouds := pos_from_idx(level, i64(idx))
		pos32: [2]f32 = linalg.to_f32(pos)
		tile, kind := get_tile(level, pos)
		rect: raylib.Rectangle = raylib.Rectangle{pos32.x, pos32.y, 1., 1.}

		screenspace_rect: raylib.Rectangle = world_to_screenspace(things, rect, current_cam)
		raylib.DrawRectangleRec(screenspace_rect, tile.color)
	}
}

//move_in_level(start: [2]f32, velocity: [2]f32, collision_mask: TileKind) -> 

// camera //
Camera :: struct {
	thing: ThingIdx,
	zoom:  f32,
	link:  list.Node,
}
get_camera_pos :: proc(things: ^ThingPool, camera_idx: ThingIdx) -> [2]f32 {
	camera, successful := get_thing(things, camera_idx)
	if successful {
		return camera.pos
	} else {
		return {}
	}
}
world_to_screenspace_vec2 :: proc(
	things: ^ThingPool,
	pos: [2]f32,
	camera_idx: ThingIdx,
) -> (
	screenspace_pos: [2]f32,
) {
	camera, successful := get_thing(things, camera_idx)
	if successful {
		screen_center: [2]f32 =
			linalg.to_f32([2]i32{raylib.GetRenderWidth(), raylib.GetRenderHeight()}) * 0.5
		center_vec: [2]f32 = screen_center - camera.pos
		screenspace_pos = (pos - camera.pos) * camera.zoom + screen_center
	}
	return screenspace_pos
}
world_to_screenspace_rect :: proc(
	things: ^ThingPool,
	rect: raylib.Rectangle,
	camera_idx: ThingIdx,
) -> (
	screenspace_rect: raylib.Rectangle,
) {
	camera, successful := get_thing(things, camera_idx)
	pos: [2]f32 = {rect.x, rect.y}
	size: [2]f32 = {rect.width, rect.height}

	pos = world_to_screenspace_vec2(things, pos, camera_idx)
	size *= camera.zoom

	if successful {
		screenspace_rect = raylib.Rectangle{pos.x, pos.y, size.x, size.y}
	}
	return screenspace_rect
}
world_to_screenspace :: proc {
	world_to_screenspace_vec2,
	world_to_screenspace_rect,
}

// Things //
jetpack_strength :: 20.
ThingFlags :: bit_set[enum {
	does_gravity,
	using_jetpack,
	camera,
	moves_towards_target,
	moves_with_mouse,
	moves_with_wasd,
	can_go_outside_level,
	freezing,
	ignore_level,
	ignore_friction,
}]
Thing :: struct {
	pos:              [2]f32, // 8 bytes
	velocity:         [2]f32, // 8 bytes
	running_strength: f32,
	drag_coefficient: f32,
	size:             f32,
	zoom:             f32,
	on_wall:          Walls,
	target:           ThingIdx,
  frame_acceleration: [2]f32,
	//on_corners: Corners,
	level:            Level, // 
	flags:            ThingFlags,
	temp_flags:       ThingFlags,
	// (TODO) (SERIALIZATION) probably a good idea to make a procedure array
	// this way i can store an index instead of a pointer, which is more memory efficient
	// also if this ever goes multiplayer a hacker can't just plop a pointer to their function in a level
	// and hack someone's computer with an edited level
	draw_thing:       proc(things: ^ThingPool, thing: Thing, camera: ThingIdx),
	on_click:         TaskProc, // is not a task, it just needs the same signature
}
nil_thing :: proc() -> Thing {
	thing: Thing = {}
	thing.draw_thing = proc(things: ^ThingPool, thing: Thing, camera: ThingIdx) {}
	return thing
}
// EASY THINGS //
easy_dot :: proc(level: Level, start: [2]f32, velocity: [2]f32) -> Thing {
	thing: Thing = {
		pos = start, // pos
		velocity = velocity, // velocity
		//calc_point_corners(level, start), // on_corners
		running_strength = 1, // running_strength
		drag_coefficient = 1.17, // drag_coefficient https://en.wikipedia.org/wiki/Drag_coefficient
		size = 0, // size of a point is 0
		on_wall = Walls{}, // on_wall
		target = ThingIdx{}, // target
		level = level, // level
		flags = {.does_gravity, .freezing}, // flags
		temp_flags = {.does_gravity, .freezing}, // temp_flags
		draw_thing = proc(things: ^ThingPool, thing: Thing, camera_idx: ThingIdx) {
			camera, successful := get_thing(things, camera_idx)
			//raylib.DrawText(fmt.caprint(thing.pos), 400, 50, 16, raylib.BLACK)
			if successful {
				raylib.DrawCircleV(
					world_to_screenspace(things, thing.pos, camera_idx),
					1. * camera.zoom,
					raylib.BLUE,
				)
			}
		}, // draw_thing
		on_click = {},
		//.do_nothing, // on_click
	}
	//if thing.on_corners == walls[.problem_brtl] || thing.on_corners == walls[.problem_bltr] {
	//thing.on_corners += walls[.down]
	//}

	return thing
}
easy_slicking :: proc(
	level: Level,
	starting_pos: [2]f32,
	mouse_target: ThingIdx,
) -> (
	slicking_thing: Thing,
) {
	slicking_thing = {
		pos = starting_pos, // position
		velocity = {0, 0}, // velocity
		running_strength = 5, // running_strength
		drag_coefficient = 1.6, // drag_coefficient
		size = 0, // size
		on_wall = Walls{}, // on_wall
		target = mouse_target, // target
		level = level, // level
		flags = {.moves_with_wasd}, // flags
		temp_flags = {.moves_with_wasd}, // temp_flags
		draw_thing = proc(things: ^ThingPool, thing: Thing, camera_idx: ThingIdx) {
			camera, successful := get_thing(things, camera_idx)

			//raylib.DrawText(fmt.caprint(thing.pos), 400, 50, 16, raylib.BLACK)
			if successful {
				raylib.DrawCircleV(
					world_to_screenspace(things, thing.pos, camera_idx),
					1. * camera.zoom,
					raylib.BLACK,
				)
			}
		}, // draw_thing
		on_click = proc(
			frame_arena: ^virtual.Arena,
			prev_game: ^GameState,
			game: ^GameState,
			next_game: ^GameState,
			prev_input: InputState,
			input: InputState,
			idx: ThingIdx,
		) {
			thing, new_thing: Thing = {}, {}
			success: bool = false
			thing, success = get_thing(&(game.things), idx)
			if !success {return}
			new_thing, success = get_thing(&(next_game.things), idx)
			if !success {return}
			switch game.hot_group {
			case .edit_tiles:
			case .edit_things:
			case .player_actions:
				switch game.hot_key {
				case 0:
					// jetpack
					if _, kind := get_tile(game.level, linalg.to_i32(thing.pos)); kind == .ice {
						new_thing.temp_flags -= {.moves_with_wasd}
						new_thing.temp_flags += {.using_jetpack, .moves_towards_target}
					}
				}
			}
			set_thing(&(next_game.things), idx, new_thing)
		}, // on_click
	}
	return slicking_thing
}
easy_stationary_camera :: proc(level: Level, pos: [2]f32, zoom: f32) -> (camera_thing: Thing) {
	camera_thing = {
		pos = pos,
		zoom = zoom,
		level = level,
		draw_thing = proc(things: ^ThingPool, thing: Thing, camera: ThingIdx) {},
		on_click = proc(
			frame_arena: ^virtual.Arena,
			prev_game: ^GameState,
			game: ^GameState,
			next_game: ^GameState,
			prev_input: InputState,
			input: InputState,
			idx: ThingIdx,
		) {},
	}
	return camera_thing
}
easy_mouse :: proc(level: Level) -> (mouse_thing: Thing) {
	mouse_thing = {
		pos = level_center(level), // position
		velocity = {0, 0}, // velocity
		running_strength = 0, // running_strength
		drag_coefficient = 0, // drag_coefficient
		size = 0, // size
		//{}, // on corners
		on_wall = Walls{}, // on_wall
		target = ThingIdx{},
		level = level, // level
		flags = {.moves_with_mouse, .ignore_level}, // flags
		temp_flags = {.moves_with_mouse, .ignore_level}, // temp_flags
		draw_thing = proc(things: ^ThingPool, thing: Thing, camera_idx: ThingIdx) {
			camera, successful := get_thing(things, camera_idx)
			if successful {
				screenspace_coords: [2]f32 = world_to_screenspace(things, thing.pos, camera_idx)
				raylib.DrawText(fmt.caprint(screenspace_coords), 100, 50, 16, raylib.BLACK)
				raylib.DrawCircleV(screenspace_coords, 1. * camera.zoom, raylib.RED)
			}
		}, // draw_thing
		on_click = proc(
			frame_arena: ^virtual.Arena,
			prev_game: ^GameState,
			game: ^GameState,
			next_game: ^GameState,
			prev_input: InputState,
			input: InputState,
			idx: ThingIdx,
		) {
			thing, success := get_thing(&(game.things), idx)
			if !success {return}
			switch game.hot_group {
			case .edit_tiles:
				kind: TileKind = TileKind(linalg.min(i32(TileKind.outside) - 1, game.hot_key))
				set_tile(game.level, linalg.to_i32(thing.pos), kind)
			case .edit_things:
				if game.hot_key < 2 {
					if tile, _ := get_tile(game.level, linalg.to_i32(thing.pos)); !tile.solid {
						switch game.hot_key {
						case 0:
							if .left_mouse not_in prev_input.pressed_buttons {
								cam_node, err := virtual.new(frame_arena, ThingNode)
								// if the frame arena is out of memory just don't make a new slicking
								// no need to crash
								// yet
								if err == .None {
									slicking: Thing = easy_slicking(game.level, thing.pos, idx)
									slicking.zoom = 45.
									slicking_idx, success := push_thing(
										&(next_game.things),
										slicking,
									)
									if success {
										cam_node.thing = slicking_idx
										list.push_front(&(game.cameras), &(cam_node.link))
									}
								}
							}
						case 1:
							rand: f32 = f32(input.random)
							push_thing(
								&(next_game.things),
								easy_dot(
									game.level,
									thing.pos,
									linalg.normalize([2]f32{linalg.sin(rand), linalg.cos(rand)}) *
									30,
								),
							)
						}
					}
				}
			case .player_actions:
			}
		}, // on_click
	}
	return mouse_thing
}

ThingIdx :: struct {
	idx:        u32,
	generation: u32,
}
check_idx :: proc(things: ^ThingPool, idx: ThingIdx) -> (valid: bool) {
	valid = true
	if things.free[idx.idx] {valid = false}
	if idx.idx >= things.offset {valid = false}
	if idx.generation != things.generations[idx.idx] {valid = false}
	return valid
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
		thing_pool.thing[thing_idx.idx] = thing
	} else {
		when STOP_ON_MISMATCHED_GENERATION_TAGS {
			panic("thing is out of date")
		}
	}
	return successful
}
push_things :: proc(
	arena: ^virtual.Arena,
	thing_pool: ^ThingPool,
	things: []Thing,
) -> (
	idxs: []ThingIdx,
	successful: bool,
) {
	amount: u32 = u32(len(things))
	err: runtime.Allocator_Error = .None
	idxs, err = virtual.make(arena, []ThingIdx, amount)
	assert(err == .None)
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
	for i in 0 ..< amount {
		idx: u32 = i + thing_pool.offset

		thing_idx: ThingIdx = {idx, thing_pool.generations[idx] + 1}
		idxs[i] = thing_idx
		thing_pool.generations[idx] = thing_idx.generation

		thing_pool.offset += 1
		set_thing(thing_pool, thing_idx, things[i])
	}
	return idxs, successful
}
push_thing :: proc(thing_pool: ^ThingPool, thing: Thing) -> (idx: ThingIdx, successful: bool) {
	scratch: virtual.Arena_Temp = get_scratch()
	things_arr: [1]Thing = {thing}
	thing_slice: []Thing = things_arr[:]
	idxs: []ThingIdx = {}
	idxs, successful = push_things(scratch.arena, thing_pool, thing_slice)
	idx = idxs[0]
	virtual.arena_temp_end(scratch)
	return idx, successful
}

draw_things :: proc(thing_pool: ^ThingPool, camera_idx: ThingIdx) {
	for i in 0 ..< thing_pool.offset {
		idx: ThingIdx = {
			idx        = i,
			generation = thing_pool.generations[i],
		}
		thing, successful := get_thing(thing_pool, idx)
		assert(successful)
		thing.draw_thing(thing_pool, thing, camera_idx)
		if i == thing_pool.offset - 1 {
			raylib.DrawText(
				fmt.caprint(thing.velocity),
				i32(f32(raylib.GetRenderWidth()) * 0.75),
				50,
				16,
				raylib.BLACK,
			)
			raylib.DrawText(
				fmt.caprint(thing.pos),
				i32(f32(raylib.GetRenderWidth()) * 0.75),
				75,
				16,
				raylib.BLACK,
			)
		}
	}
}

// tasks
TaskProc :: proc(
	frame_arena: ^virtual.Arena,
	prev_input: InputState,
	input: InputState,
	prev_game: ^GameState,
	game: ^GameState,
	idx: ThingIdx,
)
Task :: enum {
	do_nothing,
	prepare_next_thing,
	move_towards_target,
	move_with_mouse,
	move_with_wasd,
	do_gravity,
	move,
	freeze,
	handle_click,
}
tasks :: [Task]TaskProc {
	.do_nothing = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
	},
	.prepare_next_thing = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		things: ^ThingPool = &(game.things)
		thing: Thing
		success: bool
		thing, success = get_thing(things, idx)
		if !success {return}
    thing.temp_flags = thing.flags
    thing.frame_acceleration = {}
	},
	.move_towards_target = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		prev_thing, thing: Thing = {}, {}
		success: bool = false
    prev_thing, success = get_thing(&(prev_game.things), idx)
    if !success {return}
		thing, success = get_thing(&(game.things), idx)
    if !success {return}
		if .moves_towards_target in thing.temp_flags {
			// get the directin towards target
			target: Thing = thing // if theres no target then the target is itself
			if t, s := get_thing(&(game.things), thing.target); s {target = t}
			dir: [2]f32 = linalg.normalize0(target.pos - thing.pos)
			// set the velocity with running speed, or jetpack if using jetpack
			tile, _ := get_tile(game.level, linalg.to_i32(thing.pos))
			friction: f32 = tile.friction
			acceleration: f32 =
				thing.running_strength * friction if .using_jetpack not_in thing.temp_flags else jetpack_strength
      thing.frame_acceleration += acceleration * dir
    /*
			drag_vector: [2]f32 =
				linalg.normalize0(thing.velocity) *
				drag_force(
					flow_velocity = -thing.velocity,
					drag_coefficient = thing.drag_coefficient,
				)
    */
			//new_thing.velocity = thing.velocity + delta_vel - drag_vector
			set_thing(&(game.things), idx, new_thing)
		}
	},
	.move_with_mouse = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		things: ^ThingPool = &(game.things)
		thing, success := get_thing(things, idx)
		if success {
			if .moves_with_mouse in thing.temp_flags {
				mouse_strength :: 5.
				thing.velocity = input.mouse_delta * mouse_strength

				set_thing(things, idx, thing)
			}
		}
	},
	.move_with_wasd = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		things: ^ThingPool = &(game.things)
		thing, success := get_thing(things, idx)
		if success {
			if .moves_with_wasd in thing.temp_flags {
				wasd_dir: [2]f32 = {}
				if .W in input.pressed_buttons {
					wasd_dir += {0, -1}
				}
				if .A in input.pressed_buttons {
					wasd_dir += {-1, 0}
				}
				if .S in input.pressed_buttons {
					wasd_dir += {0, 1}
				}
				if .D in input.pressed_buttons {
					wasd_dir += {1, 0}
				}
				// (NOTE) while i have stopped residual drift when you ease off the gas
				//  there is still drift across axis that you are no longer using
				//  so if im going up, but then i go left or right, i will drift upwards
				// i think
				delta_vel: [2]f32 = {}
				tile, _ := get_tile(game.level, linalg.to_i32(thing.pos))
				friction: f32 = tile.friction
				if linalg.length(wasd_dir) != 0 {
					wasd_dir = wasd_dir / linalg.length(wasd_dir)
					delta_vel = wasd_dir * thing.running_strength * friction * input.delta_time
				} else {
					wasd_dir = linalg.normalize0(-thing.velocity)
					delta_vel =
						wasd_dir *
						min(
							thing.running_strength * friction * input.delta_time,
							linalg.length(-thing.velocity),
						)
				}
				thing.velocity = thing.velocity + delta_vel

				drag_vector: [2]f32 =
					linalg.normalize0(thing.velocity) *
					drag_force(
						flow_velocity = -thing.velocity,
						drag_coefficient = thing.drag_coefficient,
					)
				thing.velocity = thing.velocity - drag_vector

				set_thing(things, idx, thing)
			}
		}
	},
	.do_gravity = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		things: ^ThingPool = &(game.things)
		gravity_strength :: 100.
		thing, success := get_thing(things, idx)
		thing, success = get_thing(things, idx)
		if success {
			if .does_gravity in thing.temp_flags && .south not_in thing.on_wall {
				thing.velocity.y = thing.velocity.y + gravity_strength * input.delta_time
			}
			set_thing(things, idx, thing)
		}
	},
	.move = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		things: ^ThingPool = &(game.things)
		next_things: ^ThingPool = &(next_game.things)
		thing: Thing
		new_thing: Thing
		success: bool
		thing, success = get_thing(things, idx)
		new_thing, success = get_thing(next_things, idx)
		if success && thing.velocity != {0, 0} {
			velocity := thing.velocity
			movement: [2]f32 = velocity * input.delta_time
			pos: [2]f32 = thing.pos
			walls: Walls = thing.on_wall
			if .ignore_level not_in thing.temp_flags {
				// MOVE //
				// https://youtu.be/NbSee-XM7WA?si=AUetUTj1sKyZmTBY
				cell: CellPos = linalg.to_i32(pos)
				if .north in thing.on_wall {
					tile, kind := get_tile(thing.level, cell + {0, -1})
					if velocity.y > 0 || !tile.solid {
						walls -= {.north}
					} else {
						velocity.y = max(velocity.y, 0)
					}
				}
				if .east in thing.on_wall {
					tile, kind := get_tile(thing.level, cell + {1, 0})
					if velocity.x < 0 || !tile.solid {
						walls -= {.east}
					} else {
						velocity.x = min(velocity.x, 0)
					}
				}
				if .south in thing.on_wall {
					tile, kind := get_tile(thing.level, cell + {0, 1})
					if velocity.y < 0 || !tile.solid {
						walls -= {.south}
					} else {
						velocity.y = min(velocity.y, 0)
					}
				}
				if .west in thing.on_wall {
					tile, kind := get_tile(thing.level, cell + {-1, 0})
					if velocity.x > 0 || !tile.solid {
						walls -= {.west}
					} else {
						velocity.x = max(velocity.x, 0)
					}
				}
				movement = velocity * input.delta_time
				if movement != {} {
					len, hit := point_cast_tiled(thing.level, pos, movement)
					pos = pos + len * linalg.normalize0(movement)
					if .north in hit {
						pos.y += 0.05
					}
					if .east in hit {
						pos.x -= 0.05
					}
					if .south in hit {
						pos.y -= 0.05
					}
					if .west in hit {
						pos.x += 0.05
					}
					walls += hit
				}
				movement = pos - thing.pos
			}
			new_thing.on_wall = walls
			new_thing.pos = thing.pos + movement
			new_thing.velocity = velocity
			set_thing(next_things, idx, new_thing)
		}
	},
	.freeze = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		thing: Thing
		success: bool
		thing, success = get_thing(&(game.things), idx)
		if .freezing in thing.temp_flags {
			if tile, kind := get_tile(game.level, linalg.to_i32(thing.pos)); kind == .water {
				set_tile(game.level, linalg.to_i32(thing.pos), .ice)
			}
		}
	},
	.handle_click = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		thing: Thing
		success: bool
		thing, success = get_thing(&(game.things), idx)
		if thing.on_click != {} && .left_mouse in input.pressed_buttons {
			thing.on_click(frame_arena, prev_game, game, next_game, prev_input, input, idx)
		}
	},
}

resolve_task :: proc(
	frame_arena: ^virtual.Arena,
	prev_input: InputState,
	input: InputState,
	prev_game: ^GameState,
	game: ^GameState,
	task: Task,
) {
	prev_things: ^ThingPool = &(prev_game.things)
	things: ^ThingPool = &(game.things)
	for i in 0 ..< things.offset {
		idx: ThingIdx = {
			idx        = i,
			generation = things.generations[i],
		}
		tasks := tasks
		tasks[task](frame_arena, prev_input, input, prev_game, game, idx)
	}
}
resolve_things :: proc(
	frame_arena: ^virtual.Arena,
	prev_input: InputState,
	input: InputState,
	prev_game: ^GameState,
	game: ^GameState,
) {
	prev_things: ^ThingPool = &(prev_game.things)
	things: ^ThingPool = &(game.things)

	resolve_task(frame_arena, prev_input, input, prev_game, game, .prepare_next_thing)
	resolve_task(frame_arena, prev_input, input, prev_game, game, .move_towards_target)
	resolve_task(frame_arena, prev_input, input, prev_game, game, .move_with_mouse)
	resolve_task(frame_arena, prev_input, input, prev_game, game, .move_with_wasd)
	resolve_task(frame_arena, prev_input, input, prev_game, game, .do_gravity)
	resolve_task(frame_arena, prev_input, input, prev_game, game, .move)
	// i will want to make sure all stuff that can change level goes down here
	// spawn_dot_on_click needs a new name since it can change levels as well now
	resolve_task(frame_arena, prev_input, input, prev_game, game, .freeze)
	resolve_task(frame_arena, prev_input, input, prev_game, game, .handle_click)
}
// movement helpers //

// Input State
GameButton :: enum {
	left_mouse,
	right_mouse,
	one,
	two,
	three,
	four,
	five,
	six,
	seven,
	eight,
	nine,
	W,
	A,
	S,
	D,
	tab,
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
	if raylib.IsMouseButtonDown(raylib.MouseButton.RIGHT) {
		pressed_buttons += {.right_mouse}
	}
	if raylib.IsKeyDown(raylib.KeyboardKey.ONE) {
		pressed_buttons += {.one}
	}
	if raylib.IsKeyDown(raylib.KeyboardKey.TWO) {
		pressed_buttons += {.two}
	}
	if raylib.IsKeyDown(raylib.KeyboardKey.THREE) {
		pressed_buttons += {.three}
	}
	if raylib.IsKeyDown(raylib.KeyboardKey.FOUR) {
		pressed_buttons += {.four}
	}
	if raylib.IsKeyDown(raylib.KeyboardKey.FIVE) {
		pressed_buttons += {.five}
	}
	if raylib.IsKeyDown(raylib.KeyboardKey.SIX) {
		pressed_buttons += {.six}
	}
	if raylib.IsKeyDown(raylib.KeyboardKey.SEVEN) {
		pressed_buttons += {.seven}
	}
	if raylib.IsKeyDown(raylib.KeyboardKey.EIGHT) {
		pressed_buttons += {.eight}
	}
	if raylib.IsKeyDown(raylib.KeyboardKey.NINE) {
		pressed_buttons += {.nine}
	}
	if raylib.IsKeyDown(raylib.KeyboardKey.W) {pressed_buttons += {.W}}
	if raylib.IsKeyDown(raylib.KeyboardKey.A) {pressed_buttons += {.A}}
	if raylib.IsKeyDown(raylib.KeyboardKey.S) {pressed_buttons += {.S}}
	if raylib.IsKeyDown(raylib.KeyboardKey.D) {pressed_buttons += {.D}}
	if raylib.IsKeyDown(raylib.KeyboardKey.TAB) {pressed_buttons += {.tab}}
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
	level:     Level,
	things:    ThingPool,
	cameras:   list.List,
	hot_key:   i32,
	hot_group: HotGroup,
}
HotGroup :: enum {
	edit_tiles,
	edit_things,
	player_actions,
}
// Tick
tick :: proc(
	prev_frame_arena: ^virtual.Arena,
	frame_arena: ^virtual.Arena,
	prev_input: InputState,
	input: InputState,
	prev_game: ^GameState,
	game: ^GameState,
) {
	// mirror prev_game to game
	// mirror hotkeys
	game.hot_key = prev_game.hot_key
	game.hot_group = prev_game.hot_group
	// mirror camera list
	game.cameras.head, game.cameras.tail = prev_game.cameras.head, prev_game.cameras.tail
	// mirror level
	for kind, i in prev_game.level.data {
		game.level.data[i] = kind
	}
	// mirror things
	game.things.offset = prev_game.things.offset
	for i in 0 ..< prev_game.things.offset {
		game.things.free[i] = prev_game.things.free[i]
		game.things.generations[i] = prev_game.things.generations[i]
		game.things.thing[i] = prev_game.things.thing[i]
	}

	// item selection
	if .tab not_in input.pressed_buttons && .tab in prev_input.pressed_buttons {
		game.hot_group = HotGroup((i32(game.hot_group) + 1) % 3) // (TODO) make this better (i don't want to increase 3 every tine i ad a hotgroup
	}
	if .one in input.pressed_buttons {
		game.hot_key = 0
	}
	if .two in input.pressed_buttons {
		game.hot_key = 1
	}
	if .three in input.pressed_buttons {
		game.hot_key = 2
	}
	if .four in input.pressed_buttons {
		game.hot_key = 3
	}
	if .five in input.pressed_buttons {
		game.hot_key = 4
	}

	// camera cycling
	if .right_mouse in input.pressed_buttons && .right_mouse not_in prev_input.pressed_buttons {
		// cycle cameras if there is more than one
		if game.cameras.head.next != {} {
			game.cameras.head.prev = game.cameras.tail
			game.cameras.tail.next = game.cameras.head
			game.cameras.head = game.cameras.head.next
			game.cameras.tail = game.cameras.tail.next
			game.cameras.head.prev = {}
			game.cameras.tail.next = {}
		}
	}
	resolve_things(frame_arena, prev_input, input, prev_game, game)

	// remove invalid camera nodes
	game.cameras.head, game.cameras.tail = {}, {}
	iterator := list.iterator_head(prev_game.cameras, ThingNode, "link")
	// populate new list with valid nodes from previous list
	for camera_node in list.iterate_next(&iterator) {
		if check_idx(&(game.things), camera_node.thing) {
			copy_node, err := virtual.new(frame_arena, ThingNode)
			assert(err == .None)
			copy_node.thing = camera_node.thing
			list.push_back(&(game.cameras), &(copy_node.link))
		}
	}
	if list.is_empty(&(game.cameras)) {
		world_cam: Thing = easy_stationary_camera(
			game.level,
			level_center(game.level),
			min(
				f32(raylib.GetRenderWidth()) / f32(game.level.size.x),
				f32(raylib.GetRenderHeight()) / f32(game.level.size.y),
			) *
			0.9,
		)
		world_cam_idx, _ := push_thing(&(game.things), world_cam)
		camera_node, err := virtual.new(frame_arena, ThingNode)
		assert(err == .None)
		camera_node.thing = world_cam_idx
		list.push_back(&(game.cameras), &(camera_node.link))
	}
}
/*
tick :: proc(
	frame_arena: ^virtual.Arena,
	next_frame_arena: ^virtual.Arena,
	prev_game: ^GameState,
	game: ^GameState,
	next_game: ^GameState,
	prev_input: InputState,
	input: InputState,
) {
	assert(!list.is_empty(&game.cameras))

	game.hot_group = prev_game.hot_group
	if .tab not_in input.pressed_buttons && .tab in prev_input.pressed_buttons {
		game.hot_group = HotGroup((i32(next_game.hot_group) + 1) % 3) // (TODO) make this better (i don't want to increase 3 every tine i ad a hotgroup
	}
	game.hot_key = prev_game.hot_key
	if .one in input.pressed_buttons {
		game.hot_key = 0
	}
	if .two in input.pressed_buttons {
		game.hot_key = 1
	}
	if .three in input.pressed_buttons {
		game.hot_key = 2
	}
	if .four in input.pressed_buttons {
		game.hot_key = 3
	}
	if .five in input.pressed_buttons {
		game.hot_key = 4
	}
	if .right_mouse in input.pressed_buttons && .right_mouse not_in prev_input.pressed_buttons {
		// cycle cameras if there is more than one
		if game.cameras.head.next != {} {
			game.cameras.head.prev = game.cameras.tail
			game.cameras.tail.next = game.cameras.head
			game.cameras.head = game.cameras.head.next
			game.cameras.tail = game.cameras.tail.next
			game.cameras.head.prev = {}
			game.cameras.tail.next = {}
		}
	}
	resolve_things(frame_arena, prev_game, game, next_game, prev_input, input)


	next_game.cameras.head = {}
	next_game.cameras.tail = {}
	iterator := list.iterator_head(game.cameras, ThingNode, "link")
	// populate new list with valid nodes from previous list
	for camera_node in list.iterate_next(&iterator) {
		if check_idx(&(game.things), camera_node.thing) {
			copy_node, err := virtual.new(next_frame_arena, ThingNode)
			assert(err == .None)
			copy_node.thing = camera_node.thing
			list.push_back(&(next_game.cameras), &(copy_node.link))
		}
	}
	if list.is_empty(&(next_game.cameras)) {
		world_cam: Thing = easy_stationary_camera(
			next_game.level,
			level_center(next_game.level),
			min(
				f32(raylib.GetRenderWidth()) / f32(next_game.level.size.x),
				f32(raylib.GetRenderHeight()) / f32(next_game.level.size.y),
			) *
			0.9,
		)
		world_cam_idx, _ := push_thing(&(next_game.things), world_cam)
		camera_node, err := virtual.new(next_frame_arena, ThingNode)
		assert(err == .None)
		camera_node.thing = world_cam_idx
		list.push_back(&(next_game.cameras), &(camera_node.link))
	}

	virtual.arena_static_reset_to(frame_arena, 0)
}
*/
// drawing
draw_game :: proc(game: GameState) {
	things := game.things
	draw_level(&things, game.level, container_of(game.cameras.head, ThingNode, "link").thing)
	draw_things(&things, container_of(game.cameras.head, ThingNode, "link").thing)
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
	first_frame_arena: ^virtual.Arena,
) -> (
	prev_input: InputState,
	input_state: InputState,
	game1: GameState,
	game2: GameState,
) {
	// setup input
	prev_input = {}
	input_state = {}
	// setup level
	level_err: runtime.Allocator_Error = .None
	level_size: [2]i32 = {200, 110}
	game1.level.size = level_size
	game1.level.data, level_err = virtual.make(
		arena,
		[]TileKind,
		game1.level.size.x * game1.level.size.y,
	)
	assert(level_err == .None)
	game2.level.size = level_size
	game2.level.data, level_err = virtual.make(
		arena,
		[]TileKind,
		game2.level.size.x * game2.level.size.y,
	)
	assert(level_err == .None)
	//game.level = level


	// setup things
	thing_count :: 3000
	init_things(arena, &(game1.things), thing_count)
	init_things(arena, &(game2.things), thing_count)

	// world camera
	world_cam: Thing = easy_stationary_camera(
		game1.level,
		level_center(game1.level),
		min(
			f32(raylib.GetRenderWidth()) / f32(game1.level.size.x),
			f32(raylib.GetRenderHeight()) / f32(game1.level.size.y),
		) *
		0.9,
	)
	world_cam_idx, _ := push_thing(&(game1.things), world_cam)
	world_cam_node, err := virtual.new(first_frame_arena, ThingNode)
	assert(err == .None)
	world_cam_node.thing = world_cam_idx
	list.push_back(&(game2.cameras), &(world_cam_node.link))
	// mouse
	mouse_thing: Thing = easy_mouse(game1.level)
	mouse_thing.zoom = world_cam.zoom * 2
	mouse_idx, successful := push_thing(&(game1.things), mouse_thing)
	mouse_node: ^ThingNode = {}
	mouse_node, err = virtual.new(first_frame_arena, ThingNode)
	assert(err == .None)
	mouse_node.thing = mouse_idx
	list.push_back(&(game1.cameras), &(mouse_node.link))

	return prev_input, input_state, game1, game2
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
	global_scratch_arena = scratch
	assert(err == .None)
	frame1: virtual.Arena = {}
	err = virtual.arena_init_static(&frame1, 1 * mem.Megabyte)
	assert(err == .None)
	frame2: virtual.Arena = {}
	err = virtual.arena_init_static(&frame2, 1 * mem.Megabyte)
	assert(err == .None)


	setup_rendering()
	prev_frame_arena, frame_arena: ^virtual.Arena = &frame1, &frame2
	prev_input, input, game1, game2 := setup_game(&lifelong, prev_frame_arena)
	prev_game: ^GameState = &game1
	game: ^GameState = &game2

	/*
  for !raylib.IsKeyDown(raylib.KeyboardKey.SPACE) {
		raylib.BeginDrawing()
		raylib.ClearBackground(raylib.LIGHTGRAY)
		raylib.DrawFPS(raylib.GetRenderWidth() - 100, 50)
		draw_game(game)
		raylib.EndDrawing()
	}*/

	// game stuff
	for !raylib.WindowShouldClose() {
		// game loop
		// juggle frame arenas
		prev_prev_frame_arena: ^virtual.Arena = prev_frame_arena
		prev_frame_arena = frame_arena
		frame_arena = prev_prev_frame_arena
		virtual.arena_static_reset_to(frame_arena, 0)
		// juggle gamestates
		prev_prev_game: ^GameState = prev_game
		prev_game = game
		game = prev_prev_game
		// juggle inputs
		prev_input = input
		input = get_input_state()

		tick(prev_frame_arena, frame_arena, prev_input, input, prev_game, game)
		// rendering (TODO) section this off into a different loop
		raylib.BeginDrawing()
		raylib.ClearBackground(raylib.LIGHTGRAY)
		raylib.DrawFPS(raylib.GetRenderWidth() - 100, 50)
		raylib.DrawText(
			fmt.caprint(game.things.offset),
			i32(raylib.GetRenderWidth() / 2),
			50,
			16,
			raylib.BLACK,
		)
		draw_game(game)
		selection_count :: 5
		size: [2]i32 = {50 * selection_count, 50}
		center: [2]i32 = {raylib.GetRenderWidth() / 2, raylib.GetRenderHeight() - 50}
		raylib.DrawRectangle(
			center.x - size.x / 2,
			center.y - size.y / 2,
			size.x,
			size.y,
			raylib.DARKBLUE,
		)
		square_size: [2]i32 = {40, 40}
		square_center: [2]i32 = {center.x - size.x / 2, center.y}
		raylib.DrawRectangle(
			square_center.x + 5,
			square_center.y - square_size.y / 2,
			40,
			40,
			easy_tiles[.snow].color,
		)
		square_center.x += 50
		raylib.DrawRectangle(
			square_center.x + 5,
			square_center.y - square_size.y / 2,
			40,
			40,
			easy_tiles[.dirt].color,
		)
		square_center.x += 50
		raylib.DrawRectangle(
			square_center.x + 5,
			square_center.y - square_size.y / 2,
			40,
			40,
			easy_tiles[.ice].color,
		)
		square_center.x += 50
		raylib.DrawRectangle(
			square_center.x + 5,
			square_center.y - square_size.y / 2,
			40,
			40,
			easy_tiles[.water].color,
		)
		square_center.x += 50
		raylib.DrawRectangle(
			square_center.x + 5,
			square_center.y - square_size.y / 2,
			40,
			40,
			easy_tiles[.wall].color,
		)
		raylib.DrawText(
			fmt.caprint(game.hot_key),
			i32(raylib.GetRenderWidth() / 3),
			50,
			16,
			raylib.BLACK,
		)
		raylib.EndDrawing()

		/*
		input_state = get_input_state()
		tick(frame_arena, next_frame_arena, &prev_game, &game, &next_game, prev_input, input_state)
		prev_frame_arena := frame_arena
		frame_arena = next_frame_arena
		next_frame_arena = prev_frame_arena
		// (TODO) makes these pointers so juggling is faster
		prev_input = input_state

		prev_prev_game: GameState = prev_game
		prev_game = game
		game = next_game
		next_game = prev_prev_game
    */
	}
	raylib.CloseWindow()
}
