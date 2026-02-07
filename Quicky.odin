// TODO TOMORROW
// Snow Gun
// Enemy
// Enemy Gun
// Health
// Snow Golem
// Carrot Gun
// Level
package main
import "base:runtime"
import "core:bytes"
import "core:container/intrusive/list"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:sys/orca"
import "vendor:raylib"

// compiler flags //
STOP_ON_MISMATCHED_GENERATION_TAGS :: false
STOP_ON_POOL_OVERFLOW :: false
CHECK_EVERY_SAVE :: true

// constants
max_thing_count :: 3000

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
	fluid_mass_density: f32 = 1. / 20.,
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
Circle :: struct {
	center: [2]f32,
	size:   f32,
}
segment_circle_collision :: proc(seg: Segment, circ: Circle) -> (hit: bool) {
	dir: [2]f32 = seg.end - seg.start
	f: [2]f32 = seg.start - circ.center
	a: f32 = linalg.vector_dot(dir, dir)
	b: f32 = 2 * linalg.vector_dot(f, dir)
	c: f32 = linalg.vector_dot(f, f) - circ.size * circ.size
	discriminant: f32 = b * b - 4 * a * c
	if discriminant < 0 {
		return false
	} else {
		discriminant = math.sqrt(discriminant)
		t1: f32 = (-b - discriminant) / (2 * a)
		t2: f32 = (-b + discriminant) / (2 * a)
		if t1 >= 0 && t1 <= 1 {
			return true
		}
		if t2 >= 0 && t2 <= 1 {
			return true
		}
		return false
	}
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
Every_Tile: SetOfTiles : {.snow, .dirt, .ice, .water, .wall, .outside}
easy_tiles :: [TileKind]Tile {
	.dirt = {color = raylib.BROWN, solid = false, friction = 3.0},
	.snow = {color = raylib.RAYWHITE, solid = false, friction = 1.0},
	.ice = {color = raylib.SKYBLUE, solid = false, friction = 0.2},
	.water = {color = raylib.BLUE, solid = false, friction = 0.6},
	.wall = {color = raylib.DARKPURPLE, solid = true, friction = 1.0},
	.outside = {color = raylib.LIGHTGRAY, solid = true, friction = 1.0},
}

// Level //
Level :: struct {
	size: [2]i32,
	data: []TileKind,
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
queue_tile_change_idx :: proc(level: Level, idx: CellIdx, kind: TileKind) {
	if 0 <= idx && idx < i64(len(level.data)) {
		level.data[idx] = kind
	}
}
queue_tile_change_pos :: proc(level: Level, pos: CellPos, kind: TileKind) {
	idx, bounds := idx_from_pos(level, pos)
	if bounds {
		level.data[idx] = kind
	}
}
queue_tile_change :: proc {
	queue_tile_change_idx,
	queue_tile_change_pos,
}

paint_line :: proc(
	level: Level,
	start: [2]f32,
	end: [2]f32,
	paint_mask: SetOfTiles,
	paint: TileKind,
) {
	velocity: [2]f32 = end - start
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
	for ; len < mag; len = min(rayLength.x, rayLength.y) {
		if tile, kind := get_tile(level, cell); kind in paint_mask {
			queue_tile_change(level, cell, paint)
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
}

draw_level :: proc(things: ^ThingPool, level: Level, current_cam: ThingIdx) {
	min_cell: CellPos = linalg.to_i32(screen_to_world(things, {0, 0}, current_cam)) - [2]i32{1, 1}
	min_cell.x = max(min_cell.x, 0)
	min_cell.y = max(min_cell.y, 0)
	max_cell: CellPos =
		linalg.to_i32(
			screen_to_world(
				things,
				[2]f32{f32(raylib.GetRenderWidth()), f32(raylib.GetRenderHeight())},
				current_cam,
			),
		) +
		[2]i32{2, 2}
	max_cell.x = min(max_cell.x, level.size.x)
	max_cell.y = min(max_cell.y, level.size.y)
	for y in min_cell.y ..< max_cell.y {
		for x in min_cell.x ..< max_cell.x {
			pos: CellPos = {x, y}
			pos32: [2]f32 = linalg.to_f32(pos)
			tile, kind := get_tile(level, pos)
			rect: raylib.Rectangle = raylib.Rectangle{pos32.x, pos32.y, 1., 1.}

			screenspace_rect: raylib.Rectangle = world_to_screenspace(things, rect, current_cam)
			raylib.DrawRectangleRec(screenspace_rect, tile.color)
		}
	}
}

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
screen_to_world :: proc(
	things: ^ThingPool,
	pos: [2]f32,
	camera_idx: ThingIdx,
) -> (
	world_pos: [2]f32,
) {
	camera, successful := get_thing(things, camera_idx)
	if successful {
		screen_center: [2]f32 =
			linalg.to_f32([2]i32{raylib.GetRenderWidth(), raylib.GetRenderHeight()}) * 0.5
		world_pos = (pos - screen_center) / camera.zoom + camera.pos
	}
	return world_pos
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
	moves_with_target,
	moves_with_mouse,
	moves_with_camera,
	moves_with_wasd,
	can_go_outside_level,
	freezing,
	ignore_level,
	ignore_friction,
	shoots_ice,
	shoots_bullets,
  shoots_fire,
	shooting,
	friend,
	foe,
	piercing,
	auto_targets,
	auto_fires,
}]
// THING //
Thing :: struct {
	pos:                [2]f32, // 8 bytes
	velocity:           [2]f32, // 8 bytes
	running_strength:   f32,
	drag_coefficient:   f32,
	size:               f32,
	zoom:               f32,
	on_wall:            Walls,
	target:             ThingIdx,
	inventory1:         ThingIdx,
	inventory2:         ThingIdx,
	frame_acceleration: [2]f32,
	health:             i32,
	max_health:         i32,
	attack_strength:    i32,
	piercing:           i32,
	hurt_size:          f32,
	flags:              ThingFlags,
	temp_flags:         ThingFlags,

	// drawing
	color:              raylib.Color,
	draw_size:          [2]f32,
	draw_thing:         Draw,
	// on click
	on_click:           ClickAction, // is not a task, it just needs the same signature
	// timers
	timer_length:       f32,
	timer:              f32,
	on_timeout:         TimeoutAction,
	// on contact
	on_contact:         WallContactAction,
	sight_range:        f32,
}
nil_thing :: proc() -> Thing {
	thing: Thing = {}
	return thing
}
// EASY PRESETS //
easy_dot :: proc(level: Level, start: [2]f32, velocity: [2]f32) -> Thing {
	thing: Thing = {
		pos              = start, // pos
		velocity         = velocity, // velocity
		running_strength = 1, // running_strength
		drag_coefficient = 1.17, // drag_coefficient https://en.wikipedia.org/wiki/Drag_coefficient
		size             = 0, // size of a point is 0
		on_wall          = Walls{}, // on_wall
		target           = ThingIdx{}, // target
		flags            = {.does_gravity, .freezing, .foe}, // flags
		temp_flags       = {.does_gravity, .freezing, .foe}, // temp_flags
		color            = raylib.BLUE,
		draw_size        = {0.5, 0.5},
		draw_thing       = .draw_dot, // draw_thing
		timer            = 0,
		timer_length     = 0,
		max_health       = 100,
		health           = 100,
		hurt_size        = 0.5,
		on_timeout       = .free_yourself,
	}

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
		pos              = starting_pos, // position
		velocity         = {0, 0}, // velocity
		running_strength = 4, // running_strength
		drag_coefficient = 1.6, // drag_coefficient
		size             = 0, // size
		on_wall          = Walls{}, // on_wall
		target           = mouse_target, // target
		flags            = {.moves_with_wasd, .friend}, // flags
		color            = raylib.BLACK,
		draw_size        = {0.5, 0.5},
		draw_thing       = .draw_dot, // draw_thing
		on_click         = .slicking, // on_click
		max_health       = 500,
		health           = 500,
		hurt_size        = 0.45,
	}
	return slicking_thing
}
easy_ice_gun :: proc(thing_pool: ^ThingPool, user_idx: ThingIdx) -> (ice_gun: Thing) {
	fire_rate: f32 = 0.3
	target, success := get_thing(thing_pool, user_idx)
	ice_gun = {
		pos          = target.pos,
		target       = user_idx,
		flags        = {.moves_with_target, .ignore_level, .ignore_friction, .shoots_ice},
		timer_length = fire_rate,
		timer        = -1,
		on_timeout   = .do_nothing,
		color        = raylib.ORANGE,
		draw_size    = {0.125, 0.125},
		draw_thing   = .draw_dot,
	}
	return ice_gun
}
easy_ice_ball :: proc(pos: [2]f32, dir: [2]f32) -> (ice_ball: Thing) {
	ice_ball_speed: f32 : 70
	ice_ball = {
		pos              = pos,
		velocity         = linalg.normalize0(dir) * ice_ball_speed,
		drag_coefficient = 0.04, // streamlined body from wikipedia
		attack_strength  = 3,
		flags            = {.freezing, .ignore_friction, .piercing, .friend},
		color            = raylib.Color{152, 132, 255, 255},
		draw_size        = {0.125, 0.125},
		draw_thing       = .draw_dot,
		timer            = 0,
		timer_length     = 0.5,
		on_timeout       = .free_yourself,
		on_contact       = .bounce,
	}
	return ice_ball
}
easy_turret :: proc(pos: [2]f32) -> (turret: Thing) {
	turret = {
		pos         = pos,
		// auto target flag
		flags       = {.foe, .auto_targets, .auto_fires},
		color       = raylib.DARKGRAY,
		draw_size   = {0.6, 0.6},
		draw_thing  = .draw_dot,
		max_health  = 100,
		health      = 100,
		hurt_size   = 0.62,
		sight_range = 30,
	}
	return turret
}
easy_flame_turret :: proc(pos: [2]f32) -> (turret: Thing) {
	turret = {
		pos         = pos,
		// auto target flag
		flags       = {.foe, .auto_targets, .auto_fires},
		color       = raylib.Color{ 180, 41, 55, 255 },
		draw_size   = {0.6, 0.6},
		draw_thing  = .draw_dot,
		max_health  = 100,
		health      = 100,
		hurt_size   = 0.62,
		sight_range = 30,
	}
	return turret
}
easy_gun :: proc(thing_pool: ^ThingPool, user_idx: ThingIdx) -> (gun: Thing) {
	fire_rate: f32 = 0.3
	user, success := get_thing(thing_pool, user_idx)
	if !success {
		user = {}
	}
	gun = {
		pos          = user.pos,
		target       = user_idx,
		flags        = {.moves_with_target, .ignore_level, .ignore_friction, .shoots_bullets},
		timer_length = fire_rate,
		timer        = -1,
		on_timeout   = .do_nothing,
		color        = raylib.BLACK,
		draw_size    = {0.125, 0.125},
		draw_thing   = .draw_dot,
	}
	return gun
}
easy_flamethrower :: proc(thing_pool: ^ThingPool, user_idx: ThingIdx) -> (flamethrower: Thing) {
	fire_rate: f32 = 0
	user, success := get_thing(thing_pool, user_idx)
	if !success {
		user = {}
	}
	flamethrower = {
		pos          = user.pos,
		target       = user_idx,
		flags        = {.moves_with_target, .ignore_level, .ignore_friction, .shoots_fire},
		timer_length = fire_rate,
		timer        = -1,
		on_timeout   = .do_nothing,
		color        = raylib.ORANGE,
		draw_size    = {0.125, 0.125},
		draw_thing   = .draw_dot,
	}
  return flamethrower
}
easy_flame :: proc(pos: [2]f32, dir: [2]f32) -> (flame: Thing) {
	flame_speed: f32 : 30
	flame = {
		pos              = pos,
		velocity         = linalg.normalize0(dir) * flame_speed,
		drag_coefficient = 1.4, // streamlined body from wikipedia
		attack_strength  = 3,
		flags            = {.freezing, .ignore_friction, .piercing, .foe},
		color            = raylib.RED,
		draw_size        = {0.125, 0.125},
		draw_thing       = .draw_dot,
		timer            = 0,
		timer_length     = 0.5,
		on_timeout       = .free_yourself,
		on_contact       = .slide,
	}
  return flame
}
easy_bullet :: proc(pos: [2]f32, dir: [2]f32) -> (bullet: Thing) {
	bullet_speed: f32 : 50
	bullet = {
		pos              = pos,
		velocity         = linalg.normalize0(dir) * bullet_speed,
		drag_coefficient = 0.04, // streamlined body from wikipedia
		attack_strength  = 3,
		flags            = {.freezing, .ignore_friction, .piercing, .foe},
		color            = raylib.BLACK,
		draw_size        = {0.125, 0.125},
		draw_thing       = .draw_dot,
		timer            = 0,
		timer_length     = 0.5,
		on_timeout       = .free_yourself,
		on_contact       = .bounce,
	}
	return bullet
}
easy_stationary_camera :: proc(level: Level, pos: [2]f32, zoom: f32) -> (camera_thing: Thing) {
	camera_thing = {
		pos        = pos,
		zoom       = zoom,
		draw_thing = .draw_nothing,
	}
	return camera_thing
}
easy_mouse :: proc(level: Level) -> (mouse_thing: Thing) {
	mouse_thing = {
		zoom             = 20,
		pos              = level_center(level), // position
		velocity         = {0, 0}, // velocity
		running_strength = 0, // running_strength
		drag_coefficient = 0, // drag_coefficient
		size             = 0, // size
		//{}, // on corners
		on_wall          = Walls{}, // on_wall
		target           = ThingIdx{},
		flags            = {.moves_with_camera, .moves_with_mouse, .ignore_level}, // flags
		temp_flags       = {.moves_with_camera, .moves_with_mouse, .ignore_level}, // temp_flags
		color            = raylib.RED,
		draw_size        = {0.5, 0.5},
		draw_thing       = .draw_dot, // draw_thing
		on_click         = .mouse, // on_click
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
	free_list:   list.List,
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
/*
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
*/
push_thing :: proc(thing_pool: ^ThingPool, thing: Thing) -> (idx: ThingIdx, successful: bool) {
	free_thing: ThingIdx = {}
	is_free_thing: bool = false
	for thing_pool.free_list.head != nil {
		free_node: ^ThingNode = container_of(thing_pool.free_list.head, ThingNode, "link")
		list.pop_front(&(thing_pool.free_list))
		if free_node.thing.idx < thing_pool.offset {
			generation: u32 = thing_pool.generations[free_node.thing.idx]
			if free_node.thing.generation == generation {
				free_thing = free_node.thing
				is_free_thing = true
				break
			}
		}
	}
	if is_free_thing {
		idx = free_thing
		idx.generation += 1
		thing_pool.generations[idx.idx] += 1
		thing_pool.free[idx.idx] = false
		successful = set_thing(thing_pool, idx, thing)

	} else {
		successful = thing_pool.offset + 1 < u32(len(thing_pool.thing))
		when STOP_ON_POOL_OVERFLOW {
			if !successful {
				panic("pool is out of memory")
			}
		} else {
			if !successful {
				return {}, successful
			}
		}
		thing_pool.generations[thing_pool.offset] += 1
		idx = {
			idx        = thing_pool.offset,
			generation = thing_pool.generations[thing_pool.offset],
		}
		thing_pool.offset += 1
		thing_pool.free[idx.idx] = false
		successful = set_thing(thing_pool, idx, thing)
	}
	return idx, successful
}
free_thing :: proc(arena: ^virtual.Arena, thing_pool: ^ThingPool, idx: ThingIdx) {
	if check_idx(thing_pool, idx) {
		thing_pool.free[idx.idx] = true

		free_node, err := virtual.new(arena, ThingNode)
		if err == .None {
			free_node.thing = idx
			list.push_front(&(thing_pool.free_list), &(free_node.link))
		}
	}
}

draw_things :: proc(thing_pool: ^ThingPool, camera_idx: ThingIdx) {
	for i in 0 ..< thing_pool.offset {
		idx: ThingIdx = {
			idx        = i,
			generation = thing_pool.generations[i],
		}
		thing, successful := get_thing(thing_pool, idx)
		if !successful {continue}
		drawing := drawing
		drawing[thing.draw_thing](thing_pool, thing, camera_idx)
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
	tick_timer,
	prepare_next_thing,
	move_towards_target,
	move_with_mouse,
	move_with_wasd,
	do_gravity,
	move,
	move_with_camera,
	move_with_target,
	shoot,
	freeze,
	handle_click,
	attack,
	evaluate_life,
	auto_target,
	auto_fire,
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
	.tick_timer = proc(
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

		if thing.timer_length > 0 && thing.timer >= 0 {
			thing.timer += input.delta_time
			if thing.timer >= thing.timer_length {
				timeout_action := timeout_action
				timeout_action[thing.on_timeout](
					frame_arena,
					prev_input,
					input,
					prev_game,
					game,
					idx,
				)
			}
			set_thing(&(game.things), idx, thing)
		}
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
		set_thing(&(game.things), idx, thing)
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
		if .moves_towards_target in prev_thing.temp_flags {
			// get the directin towards target
			target: Thing = thing // if theres no target then the target is itself
			if t, s := get_thing(&(game.things), thing.target); s {target = t}
			dir: [2]f32 = linalg.normalize0(target.pos - thing.pos)
			// set the velocity with running speed, or jetpack if using jetpack
			tile, _ := get_tile(game.level, linalg.to_i32(thing.pos))
			friction: f32 = tile.friction
			acceleration: f32 =
				thing.running_strength * friction if .using_jetpack not_in prev_thing.temp_flags else jetpack_strength
			thing.frame_acceleration += acceleration * dir
			set_thing(&(game.things), idx, thing)
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
		prev_things, things: ^ThingPool = &(prev_game.things), &(game.things)
		prev_thing, thing: Thing
		success: bool
		prev_thing, success = get_thing(prev_things, idx)
		if !success {return}
		thing, success = get_thing(things, idx)
		if !success {return}
		if .moves_with_mouse in prev_thing.temp_flags {
			mouse_strength :: 5.
			thing.velocity = input.mouse_delta * mouse_strength

			set_thing(things, idx, thing)
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
		prev_things, things: ^ThingPool = &(prev_game.things), &(game.things)
		prev_thing, thing: Thing
		success: bool
		prev_thing, success = get_thing(prev_things, idx)
		if !success {return}
		thing, success = get_thing(things, idx)
		if !success {return}
		if .moves_with_wasd in prev_thing.temp_flags {
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
				delta_vel = wasd_dir * thing.running_strength * friction
			} else {
				wasd_dir = linalg.normalize0(-thing.velocity)
				delta_vel =
					wasd_dir *
					min(
						thing.running_strength * friction,
						linalg.length(-thing.velocity / input.delta_time),
					)
			}
			thing.frame_acceleration += delta_vel

			set_thing(things, idx, thing)
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
		gravity_strength :: 100.
		prev_things, things: ^ThingPool = &(prev_game.things), &(game.things)
		prev_thing, thing: Thing
		success: bool
		prev_thing, success = get_thing(prev_things, idx)
		if !success {return}
		thing, success = get_thing(things, idx)
		if !success {return}
		if .does_gravity in prev_thing.temp_flags && .south not_in thing.on_wall {
			thing.frame_acceleration.y += gravity_strength
		}
		set_thing(things, idx, thing)
	},
	.move = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		prev_things, things: ^ThingPool = &(prev_game.things), &(game.things)
		prev_thing, thing: Thing
		success: bool
		prev_thing, success = get_thing(prev_things, idx)
		if !success {return}
		thing, success = get_thing(things, idx)
		if !success {return}

		thing.velocity += thing.frame_acceleration * input.delta_time
		drag_vector: [2]f32 =
			linalg.normalize0(thing.velocity) *
			drag_force(flow_velocity = -thing.velocity, drag_coefficient = thing.drag_coefficient)
		thing.velocity -= drag_vector * input.delta_time
		if thing.velocity != {0, 0} {
			velocity := thing.velocity
			movement: [2]f32 = velocity * input.delta_time
			pos: [2]f32 = thing.pos
			walls: Walls = thing.on_wall
			if .ignore_level not_in prev_thing.temp_flags {
				// MOVE //
				// https://youtu.be/NbSee-XM7WA?si=AUetUTj1sKyZmTBY
				cell: CellPos = linalg.to_i32(pos)
				if .north in thing.on_wall {
					tile, kind := get_tile(prev_game.level, cell + {0, -1})
					if velocity.y > 0 || !tile.solid {
						walls -= {.north}
					} else {
						velocity.y = max(velocity.y, 0)
					}
				}
				if .east in thing.on_wall {
					tile, kind := get_tile(prev_game.level, cell + {1, 0})
					if velocity.x < 0 || !tile.solid {
						walls -= {.east}
					} else {
						velocity.x = min(velocity.x, 0)
					}
				}
				if .south in thing.on_wall {
					tile, kind := get_tile(prev_game.level, cell + {0, 1})
					if velocity.y < 0 || !tile.solid {
						walls -= {.south}
					} else {
						velocity.y = min(velocity.y, 0)
					}
				}
				if .west in thing.on_wall {
					tile, kind := get_tile(prev_game.level, cell + {-1, 0})
					if velocity.x > 0 || !tile.solid {
						walls -= {.west}
					} else {
						velocity.x = max(velocity.x, 0)
					}
				}
				movement = velocity * input.delta_time
				if movement != {} {
					len, hit := point_cast_tiled(prev_game.level, pos, movement)
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
				contact_actions := contact_actions
				velocity = contact_actions[thing.on_contact](game.level, cell, velocity, walls)
			}
			thing.on_wall = walls
			thing.pos = thing.pos + movement
			thing.velocity = velocity
			set_thing(things, idx, thing)
		}
	},
	.move_with_camera = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		prev_things, things: ^ThingPool = &(prev_game.things), &(game.things)
		prev_thing, thing: Thing
		success: bool
		prev_thing, success = get_thing(prev_things, idx)
		if !success {return}
		thing, success = get_thing(things, idx)
		if !success {return}

		if camera_idx := container_of(game.cameras.head, ThingNode, "link").thing;
		   .moves_with_camera in prev_thing.temp_flags && camera_idx != idx {
			camera, success := get_thing(things, camera_idx)
			if !success {return}
			prev_cam_idx := container_of(prev_game.cameras.head, ThingNode, "link")
			prev_camera: Thing
			prev_camera, success = get_thing(prev_things, prev_cam_idx.thing)
			if !success {return}
			delta_pos: [2]f32 = camera.pos - prev_camera.pos
			thing.pos += delta_pos
			set_thing(things, idx, thing)
		}
	},
	.move_with_target = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		prev_things, things: ^ThingPool = &(prev_game.things), &(game.things)
		prev_thing, thing: Thing
		success: bool
		prev_thing, success = get_thing(prev_things, idx)
		if !success {return}
		thing, success = get_thing(things, idx)
		if !success {return}

		if .moves_with_target in prev_thing.temp_flags {
			prev_target, current_target := Thing{}, Thing{}
			prev_target, success = get_thing(prev_things, prev_thing.target)
			if !success {return}
			current_target, success = get_thing(things, thing.target)
			if !success {return}
			delta_pos: [2]f32 = current_target.pos - prev_target.pos
			thing.pos += delta_pos
			set_thing(things, idx, thing)
		}
	},
	.shoot = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		prev_things, things: ^ThingPool = &(prev_game.things), &(game.things)
		prev_thing, thing: Thing
		success: bool
		prev_thing, success = get_thing(prev_things, idx)
		if !success {return}
		thing, success = get_thing(things, idx)
		if !success {return}
		if .shooting in prev_thing.temp_flags {
			if thing.timer_length <= 0 || thing.timer > thing.timer_length || thing.timer < 0 {
				user, target: Thing = {}, {}
				user, success = get_thing(prev_things, thing.target)
				if !success {return}
				target, success = get_thing(prev_things, user.target)
				if !success {return}
				if .shoots_ice in prev_thing.temp_flags {
					ice_ball: Thing = easy_ice_ball(thing.pos, target.pos - thing.pos)
					ice_ball_idx, success := push_thing(things, ice_ball)
				}
				if .shoots_bullets in prev_thing.temp_flags {
					bullet: Thing = easy_bullet(thing.pos, target.pos - thing.pos)
					bullet_idx, success := push_thing(things, bullet)
				}
      if .shoots_fire in prev_thing.temp_flags {
        fire: Thing = easy_flame(thing.pos, target.pos - thing.pos)
        bullet_idx, success := push_thing(things, fire)
      }
				thing.timer = 0
				set_thing(things, idx, thing)
			}
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
		prev_things, things: ^ThingPool = &(prev_game.things), &(game.things)
		prev_thing, thing: Thing
		success: bool
		prev_thing, success = get_thing(prev_things, idx)
		if !success {return}
		thing, success = get_thing(things, idx)
		if !success {return}

		if .freezing in prev_thing.temp_flags {
			paint_line(game.level, prev_thing.pos, thing.pos, {.water}, .ice)
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
		if !success {return}
		if thing.on_click != .do_nothing && .left_mouse in input.pressed_buttons {
			click_actions := click_actions
			click_actions[thing.on_click](frame_arena, prev_input, input, prev_game, game, idx)
		}
	},
	.attack = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		prev_things, things: ^ThingPool = &(prev_game.things), &(game.things)
		prev_thing, thing: Thing
		success: bool
		prev_thing, success = get_thing(prev_things, idx)
		if !success {return}
		thing, success = get_thing(things, idx)
		if !success {return}
		if thing.attack_strength > 0 {
			if .friend in prev_thing.temp_flags {
				for i in 0 ..< things.offset {
					if i == idx.idx {continue}
					if things.free[i] {continue}
					other_idx: ThingIdx = {
						idx        = i,
						generation = things.generations[i],
					}
					other_thing, _ := get_thing(things, other_idx)
					prev_other_thing, success := get_thing(things, other_idx)
					if !success {continue}
					if .foe in prev_other_thing.temp_flags &&
					   other_thing.hurt_size > 0 &&
					   other_thing.max_health > 0 {
						circle: Circle = {
							center = other_thing.pos,
							size   = other_thing.hurt_size,
						}
						seg: Segment = {
							start = prev_thing.pos,
							end   = thing.pos,
						}
						if segment_circle_collision(seg, circle) {
							other_thing.health -= thing.attack_strength
							set_thing(things, other_idx, other_thing)
							if .piercing in prev_thing.temp_flags {
								thing.piercing -= 1
								set_thing(things, idx, thing)
							}
						}
					}
				}
			}
			if .foe in prev_thing.temp_flags {
				for i in 0 ..< things.offset {
					if i == idx.idx {continue}
					if things.free[i] {continue}
					other_idx: ThingIdx = {
						idx        = i,
						generation = things.generations[i],
					}
					other_thing, _ := get_thing(things, other_idx)
					prev_other_thing, success := get_thing(things, other_idx)
					if !success {continue}
					if .friend in prev_other_thing.temp_flags &&
					   other_thing.hurt_size > 0 &&
					   other_thing.max_health > 0 {
						circle: Circle = {
							center = other_thing.pos,
							size   = other_thing.hurt_size,
						}
						seg: Segment = {
							start = prev_thing.pos,
							end   = thing.pos,
						}
						if segment_circle_collision(seg, circle) {
							other_thing.health -= thing.attack_strength
							set_thing(things, other_idx, other_thing)
							if .piercing in prev_thing.temp_flags {
								thing.piercing -= 1
								set_thing(things, idx, thing)
							}
						}
					}
				}
			}
		}
	},
	.evaluate_life = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		prev_things, things: ^ThingPool = &(prev_game.things), &(game.things)
		prev_thing, thing: Thing
		success: bool
		prev_thing, success = get_thing(prev_things, idx)
		if !success {return}
		thing, success = get_thing(things, idx)
		if !success {return}
		if thing.max_health != 0 {
			if thing.health < 0 {
				free_thing(frame_arena, things, idx)
				return
			}
		}
		if .piercing in prev_thing.temp_flags {
			if thing.piercing < 0 {
				free_thing(frame_arena, things, idx)
				return
			}
		}
	},
	.auto_target = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		prev_things, things: ^ThingPool = &(prev_game.things), &(game.things)
		prev_thing, thing: Thing
		success: bool
		prev_thing, success = get_thing(prev_things, idx)
		if !success {return}
		thing, success = get_thing(things, idx)
		if !success {return}
		if .auto_targets in prev_thing.temp_flags {
			closest_target: ThingIdx = {}
			closest_distance: f32 = thing.sight_range
			if .friend in prev_thing.temp_flags {
			}
			if .foe in prev_thing.temp_flags {
				for i in 0 ..< things.offset {
					if i == idx.idx {continue}
					if things.free[i] {continue}
					other_idx: ThingIdx = {
						idx        = i,
						generation = things.generations[i],
					}
					other_thing, _ := get_thing(things, other_idx)
					prev_other_thing, success := get_thing(things, other_idx)
					if !success {continue}
					if .friend in prev_other_thing.temp_flags &&
					   other_thing.hurt_size > 0 &&
					   other_thing.max_health > 0 {
						distance: f32 =
							linalg.length(other_thing.pos - thing.pos) -
							other_thing.hurt_size * 0.5
						if distance < closest_distance {
							closest_target = other_idx
							closest_distance = distance
						}
					}
				}
			}
			thing.target = closest_target
			set_thing(things, idx, thing)
		}
	},
	.auto_fire = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		prev_things, things: ^ThingPool = &(prev_game.things), &(game.things)
		prev_thing, thing: Thing
		success: bool
		prev_thing, success = get_thing(prev_things, idx)
		if !success {return}
		thing, success = get_thing(things, idx)
		if !success {return}
		if .auto_fires in prev_thing.temp_flags {
			if check_idx(things, thing.target) {
				if check_idx(things, thing.inventory1) {
					item, _ := get_thing(things, thing.inventory1)
					item.temp_flags += {.shooting}
					set_thing(things, thing.inventory1, item)
				}
			}
		}
	},
}

ClickAction :: enum {
	do_nothing,
	slicking,
	mouse,
}
click_actions :: [ClickAction]TaskProc {
	.do_nothing = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {},
	.slicking = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		thing: Thing = {}
		success: bool = false
		thing, success = get_thing(&(game.things), idx)
		if !success {return}
		switch game.hot_group {
		case .edit_tiles:
		case .edit_things:
		case .player_actions:
			switch game.hot_key {
			case 0:
				// jetpack
				if _, kind := get_tile(game.level, linalg.to_i32(thing.pos)); kind == .ice {
					thing.temp_flags -= {.moves_with_wasd}
					thing.temp_flags += {.using_jetpack, .moves_towards_target}
				}
			case 1:
				// ice_gun
				ice_gun, success := get_thing(&(game.things), thing.inventory2)
				if success {
					ice_gun.temp_flags += {.shooting}
					set_thing(&(game.things), thing.inventory2, ice_gun)
				}
			}
		}
		set_thing(&(game.things), idx, thing)
	},
	.mouse = proc(
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
		switch game.hot_group {
		case .edit_tiles:
			kind: TileKind = TileKind(linalg.min(i32(TileKind.outside) - 1, game.hot_key))
			paint_line(game.level, prev_thing.pos, thing.pos, Every_Tile, kind)
		//queue_tile_change(game.level, linalg.to_i32(thing.pos), kind)
		case .edit_things:
			if game.hot_key < 9 {
				if tile, _ := get_tile(game.level, linalg.to_i32(thing.pos)); !tile.solid {
					switch game.hot_key {
					case 0:
						if .left_mouse not_in prev_input.pressed_buttons {
							cam_node, err := virtual.new(frame_arena, ThingNode)
							// if the frame arena is out of memory just don't make a new slicking
							// no need to crash
							// yet
							if err == .None {
								slicking_idx, success := push_thing(&(game.things), {})
								if success {
									slicking: Thing = easy_slicking(game.level, thing.pos, idx)
									slicking.zoom = 45.
									set_thing(&(game.things), slicking_idx, slicking)

									ice_gun: Thing = easy_ice_gun(&(game.things), slicking_idx)
									ice_gun_idx, succes := push_thing(&(game.things), ice_gun)
									if success {
										slicking.inventory2 = ice_gun_idx
										set_thing(&(game.things), slicking_idx, slicking)
									}
									cam_node.thing = slicking_idx
									list.push_front(&(game.cameras), &(cam_node.link))
								}
							}
						}
					case 1:
						if .left_mouse not_in prev_input.pressed_buttons {
							turret_idx, success := push_thing(&(game.things), {})
							if success {
								turret: Thing = easy_turret(thing.pos)
								set_thing(&(game.things), turret_idx, turret)
								gun: Thing = easy_gun(&(game.things), turret_idx)
								gun_idx, success := push_thing(&(game.things), gun)
								if success {
									turret.inventory1 = gun_idx
									set_thing(&(game.things), turret_idx, turret)
								}
							}
						}
        case 2: 
						if .left_mouse not_in prev_input.pressed_buttons {
							turret_idx, success := push_thing(&(game.things), {})
							if success {
								turret: Thing = easy_flame_turret(thing.pos)
								set_thing(&(game.things), turret_idx, turret)
								flame_thrower: Thing = easy_flamethrower(&(game.things), turret_idx)
								flame_thrower_idx, success := push_thing(&(game.things), flame_thrower)
								if success {
									turret.inventory1 = flame_thrower_idx
									set_thing(&(game.things), turret_idx, turret)
								}
							}
						}
					case 3:
						rand: f32 = f32(input.random)
						push_thing(
							&(game.things),
							easy_dot(
								game.level,
								thing.pos,
								linalg.normalize([2]f32{linalg.sin(rand), linalg.cos(rand)}) * 30,
							),
						)
					}
				}
			}
		case .player_actions:
		}
	},
}
TimeoutAction :: enum {
	do_nothing,
	free_yourself,
}
timeout_action :: [TimeoutAction]TaskProc {
	.do_nothing = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {},
	.free_yourself = proc(
		frame_arena: ^virtual.Arena,
		prev_input: InputState,
		input: InputState,
		prev_game: ^GameState,
		game: ^GameState,
		idx: ThingIdx,
	) {
		free_thing(frame_arena, &(game.things), idx)
	},
}
WallContactAction :: enum {
	slide,
	stop,
	bounce,
}
contact_actions :: [WallContactAction]proc(
	level: Level,
	cell: CellPos,
	vel: [2]f32,
	walls: Walls,
) -> (
	vel_out: [2]f32
) {
	.slide = proc(level: Level, cell: CellPos, vel: [2]f32, walls: Walls) -> (vel_out: [2]f32) {
		vel_out = vel
		return vel_out
	},
	.stop = proc(level: Level, cell: CellPos, vel: [2]f32, walls: Walls) -> (vel_out: [2]f32) {
		vel_out = vel
		if walls != {} {
			vel_out = {}
		}
		return vel_out
	},
	.bounce = proc(level: Level, cell: CellPos, vel: [2]f32, walls: Walls) -> (vel_out: [2]f32) {
		vel_out = vel
		surface_normal: [2]f32 = {0, 0}
		if .north in walls {
			surface_normal += {0, 1}
		}
		if .east in walls {
			surface_normal += {-1, 0}
		}
		if .south in walls {
			surface_normal += {0, -1}
		}
		if .west in walls {
			surface_normal += {1, 0}
		}
		surface_normal = linalg.normalize0(surface_normal)
		if surface_normal != {0, 0} {
			vel_out = vel - 2 * (linalg.vector_dot(surface_normal, vel)) * surface_normal
		}
		return vel_out
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
	resolve_task(frame_arena, prev_input, input, prev_game, game, .move_with_camera)
	resolve_task(frame_arena, prev_input, input, prev_game, game, .move_with_target)
	// i will want to make sure all stuff that can change level goes down here
	// spawn_dot_on_click needs a new name since it can change levels as well now
	resolve_task(frame_arena, prev_input, input, prev_game, game, .attack)
	resolve_task(frame_arena, prev_input, input, prev_game, game, .shoot)
	resolve_task(frame_arena, prev_input, input, prev_game, game, .freeze)
	resolve_task(frame_arena, prev_input, input, prev_game, game, .handle_click)
	resolve_task(frame_arena, prev_input, input, prev_game, game, .evaluate_life)
	resolve_task(frame_arena, prev_input, input, prev_game, game, .tick_timer)
	resolve_task(frame_arena, prev_input, input, prev_game, game, .auto_target)
	resolve_task(frame_arena, prev_input, input, prev_game, game, .auto_fire)
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
	ctrl,
}
GameButtons :: bit_set[GameButton]
InputState :: struct {
	// must be smol
	delta_time:      f32, // 4 bytes
	mouse_delta:     [2]f32, // 8 bytes, prev_game)
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
	if raylib.IsKeyDown(raylib.KeyboardKey.LEFT_CONTROL) {pressed_buttons += {.ctrl}}
	if raylib.IsKeyDown(raylib.KeyboardKey.RIGHT_CONTROL) {pressed_buttons += {.ctrl}}
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
	hot_key:   i32,
	hot_group: HotGroup,
	level:     Level,
	things:    ThingPool,
	cameras:   list.List,
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
	// mirror things to new frame_arena
	game.things.free_list = {}
	free_iterator := list.iterator_head(prev_game.things.free_list, ThingNode, "link")
	for free_node in list.iterate_next(&free_iterator) {
		copy_node, err := virtual.new(frame_arena, ThingNode)
		if err == .None {
			copy_node.thing = free_node.thing
			list.push_back(&(game.things.free_list), &(copy_node.link))
		}
	}
	// serialize_game
	if .S in input.pressed_buttons &&
	   .S not_in prev_input.pressed_buttons &&
	   .ctrl in input.pressed_buttons {
		serialize_game(prev_input, prev_game)
	}
	// mirror prev_game to game
	// mirror hotkeys
	game.hot_key = prev_game.hot_key
	game.hot_group = prev_game.hot_group
	// mirror camera list
	// remove invalid camera nodes
	game.cameras.head, game.cameras.tail = {}, {}
	iterator := list.iterator_head(prev_game.cameras, ThingNode, "link")
	// populate new list with valid nodes from previous list
	for camera_node in list.iterate_next(&iterator) {
		if check_idx(&(prev_game.things), camera_node.thing) {
			copy_node, err := virtual.new(frame_arena, ThingNode)
			if err == .None {
				copy_node.thing = camera_node.thing
				list.push_back(&(game.cameras), &(copy_node.link))
			}
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

	resolve_things(frame_arena, prev_input, input, prev_game, game)

	tst := 4
	fmt.println(game.things.free[tst])
}
// drawing
DrawProc :: proc(things: ^ThingPool, thing: Thing, camera: ThingIdx)
Draw :: enum {
	draw_nothing,
	draw_dot,
}
drawing :: [Draw]DrawProc {
	.draw_nothing = proc(things: ^ThingPool, thing: Thing, camera_idx: ThingIdx) {},
	.draw_dot = proc(things: ^ThingPool, thing: Thing, camera_idx: ThingIdx) {
		camera, successful := get_thing(things, camera_idx)
		//raylib.DrawText(fmt.caprint(thing.pos), 400, 50, 16, raylib.BLACK)
		if successful {
			raylib.DrawCircleV(
				world_to_screenspace(things, thing.pos, camera_idx),
				thing.draw_size.x * camera.zoom,
				thing.color,
			)
		}
	},
}

draw_game :: proc(game: ^GameState) {
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
setup_game_with_load :: proc(
	arena: ^virtual.Arena,
	first_frame_arena: ^virtual.Arena,
) -> (
	prev_input: InputState,
	input_state: InputState,
	game1: GameState,
	game2: GameState,
) {
	prev_input, game1 = load_game(arena, first_frame_arena)
	// setup next game
	input_state = {}
	level_err: runtime.Allocator_Error = .None
	game2.level.size = game1.level.size
	game2.level.data, level_err = virtual.make(
		arena,
		[]TileKind,
		game2.level.size.x * game2.level.size.y,
	)
	assert(level_err == .None)
	init_things(arena, &(game2.things), max_thing_count)

	return prev_input, input_state, game1, game2
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
	level_size: [2]i32 = {500, 500}
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
	init_things(arena, &(game1.things), max_thing_count)
	init_things(arena, &(game2.things), max_thing_count)

	// world camera
	world_cam: Thing = easy_stationary_camera(
		game1.level,
		level_center(game1.level),
		min(
			f32(raylib.GetRenderWidth()) / f32(game1.level.size.x),
			f32(raylib.GetRenderHeight()) / f32(game1.level.size.y),
		),
	)
	world_cam_idx, _ := push_thing(&(game1.things), world_cam)
	world_cam_node, err := virtual.new(first_frame_arena, ThingNode)
	assert(err == .None)
	world_cam_node.thing = world_cam_idx
	list.push_back(&(game1.cameras), &(world_cam_node.link))
	// mouse
	mouse_thing: Thing = easy_mouse(game1.level)
	mouse_idx, successful := push_thing(&(game1.things), mouse_thing)
	mouse_node: ^ThingNode = {}
	mouse_node, err = virtual.new(first_frame_arena, ThingNode)
	assert(err == .None)
	mouse_node.thing = mouse_idx
	list.push_front(&(game1.cameras), &(mouse_node.link))

	return prev_input, input_state, game1, game2
}

// SERIALIZATION //
serialize_game :: proc(prev_input: InputState, prev_game: ^GameState) -> (successful: bool) {
	scratch := get_scratch()
	// aos
	aos_things, err := virtual.make(scratch.arena, []Thing, prev_game.things.offset)
	if err != .None {
		virtual.arena_temp_end(scratch)
		return false
	}
	for i in 0 ..< prev_game.things.offset {
		aos_things[i] = prev_game.things.thing[i]
	}
	// cameras
	camera_count: u32 = 0
	camera_iterator := list.iterator_head(prev_game.cameras, ThingNode, "link")
	for camera in list.iterate_next(&camera_iterator) {
		camera_count += 1
	}
	camera_slice: []ThingIdx
	camera_slice, err = virtual.make(scratch.arena, []ThingIdx, camera_count)
	if err != .None {
		virtual.arena_temp_end(scratch)
		return false
	}
	camera_iterator = list.iterator_head(prev_game.cameras, ThingNode, "link")
	camera_index: i32 = 0
	for camera in list.iterate_next(&camera_iterator) {
		camera_slice[camera_index] = camera.thing
		camera_index += 1
	}

	// free list
	free_node_count: u32 = 0
	free_iterator := list.iterator_head(prev_game.things.free_list, ThingNode, "link")
	for free_node in list.iterate_next(&free_iterator) {
		free_node_count += 1
	}
	free_list_slice: []ThingIdx
	free_list_slice, err = virtual.make(scratch.arena, []ThingIdx, free_node_count)
	if err != .None {
		virtual.arena_temp_end(scratch)
		return false
	}
	free_iterator = list.iterator_head(prev_game.things.free_list, ThingNode, "link")
	free_index: i32 = 0
	for free_node in list.iterate_next(&free_iterator) {
		free_list_slice[free_index] = free_node.thing
		free_index += 1
	}


	buffers: [][]byte = {
		// Input //
		slice.to_bytes([]InputState{prev_input}),
		// Game //
		slice.to_bytes([]i32{prev_game.hot_key}),
		slice.to_bytes([]HotGroup{prev_game.hot_group}),
		// level //
		slice.to_bytes([][2]i32{prev_game.level.size}),
		slice.to_bytes(prev_game.level.data),
		// things //
		// offset
		slice.to_bytes([]u32{prev_game.things.offset}),
		// generations
		slice.to_bytes(prev_game.things.generations[:prev_game.things.offset]),
		// free
		slice.to_bytes([]u32{free_node_count}),
		slice.to_bytes(free_list_slice),
		slice.to_bytes(prev_game.things.free[:prev_game.things.offset]),
		// thing
		slice.to_bytes(aos_things),
		// cameras //
		slice.to_bytes([]u32{camera_count}),
		slice.to_bytes(camera_slice),
	}
	big_buff: []byte
	big_buff, err = bytes.concatenate_safe(buffers[:], virtual.arena_allocator(scratch.arena))
	if err != .None {
		virtual.arena_temp_end(scratch)
		return false
	}
	raylib.SaveFileData("seri", raw_data(big_buff), i32(len(big_buff)))

	when CHECK_EVERY_SAVE {
		// we don't need the old scratch for the check so we'll just empty it real quick
		virtual.arena_temp_end(scratch)
		scratch = get_scratch()
		seri_input, seri_game := load_game(scratch.arena, scratch.arena)
		assert(seri_input == prev_input)
		assert(seri_game.hot_key == prev_game.hot_key)
		assert(seri_game.hot_group == prev_game.hot_group)
		assert(seri_game.level.size == prev_game.level.size)
		for kind, i in prev_game.level.data {
			assert(seri_game.level.data[i] == kind)
		}
		assert(seri_game.things.offset == prev_game.things.offset)
		for i in 0 ..< prev_game.things.offset {
			assert(prev_game.things.thing[i] == seri_game.things.thing[i])
		}
		free_iterator = list.iterator_head(prev_game.things.free_list, ThingNode, "link")
		seri_free_iterator := list.iterator_head(seri_game.things.free_list, ThingNode, "link")
		for free_node in list.iterate_next(&free_iterator) {
			seri_free_node, ok := list.iterate_next(&seri_free_iterator)
			assert(ok)
			assert(free_node.thing == seri_free_node.thing)
		}


		camera_iterator = list.iterator_head(prev_game.cameras, ThingNode, "link")
		seri_camera_iterator := list.iterator_head(seri_game.cameras, ThingNode, "link")
		for camera in list.iterate_next(&camera_iterator) {
			seri_camera, ok := list.iterate_next(&seri_camera_iterator)
			assert(ok)
			assert(camera.thing == seri_camera.thing)
		}
	}
	// prev_game.level data is a problem
	// prev_game.thing_pool is a problem
	// cameras might require ptr arithmetic on load
	virtual.arena_temp_end(scratch)
	return true
}
load_game :: proc(
	arena: ^virtual.Arena,
	frame_arena: ^virtual.Arena,
) -> (
	seri_input: InputState,
	seri_game: GameState,
) {
	scratch: virtual.Arena_Temp = get_scratch()
	data_size: i32 = 0
	// (TODO) use io stream or something instead so i can use scratch arena instead of context allocator
	seri_data: [^]byte = raylib.LoadFileData(fmt.caprintf("%sseri", #directory), &data_size)
	seri_bytes: []byte = seri_data[:data_size]

	init_things(arena, &(seri_game.things), max_thing_count)


	offset: u32 = 0

	seri_input = slice.reinterpret([]InputState, seri_bytes[offset:size_of(InputState)])[0]
	offset += size_of(InputState)

	seri_game.hot_key = slice.reinterpret([]i32, seri_bytes[offset:offset + size_of(i32)])[0]
	offset += size_of(i32)

	seri_game.hot_group =
		slice.reinterpret([]HotGroup, seri_bytes[offset:offset + size_of(HotGroup)])[0]
	offset += size_of(HotGroup)

	seri_game.level.size =
		slice.reinterpret([][2]i32, seri_bytes[offset:offset + size_of([2]f32)])[0]
	offset += size_of([2]f32)

	level_count: u32 = u32(seri_game.level.size.x * seri_game.level.size.y)
	level_data_slice: []TileKind = slice.reinterpret(
		[]TileKind,
		seri_bytes[offset:offset + size_of(TileKind) * level_count],
	)
	seri_game.level.data = slice.clone(level_data_slice, virtual.arena_allocator(arena))
	offset += size_of(TileKind) * level_count

	seri_game.things.offset = slice.reinterpret([]u32, seri_bytes[offset:offset + size_of(u32)])[0]
	offset += size_of(u32)

	seri_generations: []u32 = slice.reinterpret(
		[]u32,
		seri_bytes[offset:offset + size_of(u32) * seri_game.things.offset],
	)
	offset += size_of(u32) * seri_game.things.offset

	seri_free_count: u32 = slice.reinterpret([]u32, seri_bytes[offset:offset + size_of(u32)])[0]
	offset += size_of(u32)
	seri_free_things: []ThingIdx = slice.reinterpret(
		[]ThingIdx,
		seri_bytes[offset:offset + size_of(ThingIdx) * seri_free_count],
	)
	offset += size_of(ThingIdx) * seri_free_count
	for free_thing in seri_free_things {
		free_node, err := virtual.new(frame_arena, ThingNode)
		free_node.thing = free_thing
		list.push_back(&(seri_game.things.free_list), &(free_node.link))
	}

	seri_free: []bool = slice.reinterpret(
		[]bool,
		seri_bytes[offset:offset + size_of(bool) * seri_game.things.offset],
	)
	offset += size_of(bool) * seri_game.things.offset

	seri_things: []Thing = slice.reinterpret(
		[]Thing,
		seri_bytes[offset:offset + size_of(Thing) * seri_game.things.offset],
	)
	offset += size_of(Thing) * seri_game.things.offset

	for i in 0 ..< seri_game.things.offset {
		seri_game.things.generations[i] = seri_generations[i]
		seri_game.things.free[i] = seri_free[i]
		seri_game.things.thing[i] = seri_things[i]
	}

	seri_camera_count: u32 = slice.reinterpret([]u32, seri_bytes[offset:offset + size_of(u32)])[0]
	offset += size_of(i32)
	seri_cameras: []ThingIdx = slice.reinterpret(
		[]ThingIdx,
		seri_bytes[offset:offset + size_of(ThingIdx) * seri_camera_count],
	)
	offset += size_of(ThingIdx) * seri_camera_count

	for camera in seri_cameras {
		camera_node, err := virtual.new(frame_arena, ThingNode)
		camera_node.thing = camera
		list.push_back(&(seri_game.cameras), &(camera_node.link))
	}

	raylib.UnloadFileData(seri_data)
	return seri_input, seri_game
}

main :: proc() {
	fmt.println(estimate_max_runtime(mem.Megabyte), "minutes")
	fmt.println(size_of(Thing) + 4 + 1)
	//crash: ^virtual.Arena
	lifelong: virtual.Arena = {}
	err: runtime.Allocator_Error = {}
	err = virtual.arena_init_static(&lifelong, 2 * mem.Megabyte)
	assert(err == .None)
	scratch: virtual.Arena = {}
	err = virtual.arena_init_static(&scratch, 2 * mem.Megabyte)
	global_scratch_arena = scratch
	assert(err == .None)
	frame1: virtual.Arena = {}
	err = virtual.arena_init_static(&frame1, 2 * mem.Megabyte)
	assert(err == .None)
	frame2: virtual.Arena = {}
	err = virtual.arena_init_static(&frame2, 2 * mem.Megabyte)
	assert(err == .None)


	setup_rendering()

	prev_frame_arena, frame_arena: ^virtual.Arena = &frame1, &frame2
	//prev_input, input, game1, game2 := setup_game_with_load(&lifelong, prev_frame_arena)
	prev_input, input, game1, game2 := setup_game(&lifelong, prev_frame_arena)
	prev_game: ^GameState = &game1
	game: ^GameState = &game2
	tick(prev_frame_arena, frame_arena, prev_input, input, prev_game, game)

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
		raylib.DrawText(
			fmt.caprint(game.things.offset),
			i32(raylib.GetRenderWidth() / 2),
			50,
			16,
			raylib.BLACK,
		)
		raylib.DrawFPS(raylib.GetRenderWidth() - 100, 50)
		raylib.EndDrawing()

	}
	//serialize_game(prev_input, prev_game)
	raylib.CloseWindow()
}
