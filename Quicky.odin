package main
import "core:fmt"
import "core:math/linalg"
import "vendor:raylib"
import "core:mem/virtual"
import "core:mem"
import "base:runtime"

// compiler flags //
STOP_ON_MISMATCHED_GENERATION_TAGS :: true
STOP_ON_POOL_OVERFLOW :: true

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
ThingIdx :: struct {
  idx: u32,
  generation: u32
}
Thing :: struct {
	pos:        [2]f32,
  level:      Level,
  draw_thing: proc(thing: ThingIdx, camera: Camera),
}
Things :: struct {
  count: u32,
  offset: u32,

/* vim macro for easily updating Things
0wwwi[]
*/
	pos:        [][2]f32,
  level:      []Level,
  draw_thing: []proc(thing: ThingIdx, camera: Camera),

  generation: []u32
}
init_thingpool :: proc(arena: ^virtual.Arena, thing_pool: ^Things, count: u32) {
  err: runtime.Allocator_Error
  thing_pool.count = count

/* vim macro for easily updating init_thing_pool
0withing_pool.wwi, err = virtual.make(arena, xxA count); assert(err == .None)
*/
  thing_pool.pos, err = virtual.make(arena, [][2]f32, count); assert(err == .None)
  thing_pool.level, err = virtual.make(arena, []Level, count); assert(err == .None)
  thing_pool.draw_thing, err = virtual.make(arena, []proc(thing_idx: ThingIdx, camera:Camera), count); assert(err == .None)

  thing_pool.generation, err = virtual.make(arena, []u32, count); assert(err == .None)

}
get_thing :: proc(thing_pool: Things, thing_idx: ThingIdx) -> (thing: Thing, successful: bool = false) {
  assert(thing_idx.idx < thing_pool.count)
  if thing_idx.generation == thing_pool.generation[thing_idx.idx] {
    successful = true
    when STOP_ON_MISMATCHED_GENERATION_TAGS {
      panic("thing is out of date")
    }
  }
  thing = Thing{
/* vim macro for easily updating get_thing
0wwv$hxyiw$a = pAbithing_pool.A[thing_idx.idx],
*/
	pos = thing_pool.pos[thing_idx.idx],
  level = thing_pool.level[thing_idx.idx],
  draw_thing = thing_pool.draw_thing[thing_idx.idx],
  }
  return thing, successful
}
set_thing :: proc(thing_pool: Things, thing_idx: ThingIdx, thing: Thing) {
  assert(thing_idx.idx < thing_pool.count)
  if thing_idx.generation == thing_pool.generation[thing_idx.idx] {
    successful = true
    when STOP_ON_MISMATCHED_GENERATION_TAGS {
      panic("thing is out of date")
    }
  }
}
thingpool_push :: proc(thing_pool: ^Things, amount: u32) -> (starting_idx: ThingIdx, successful: bool) {
  successful = thing_pool.offset + amount < thing_pool.count
  when STOP_ON_POOL_OVERFLOW {
    if !successful {
      panic("pool is out of memory")
    }
  }
  for (idx in thing_pool.offset..<(thing_poo.offset + amount)) {
    thing_pool.generation[idx] += 1
    thing_idx: ThingIdx = {idx, thing_pool.generation[idx]}
    set_thing(thing_pool^, thing_idx, {0})
  }
  thing_pool.offset += amount
}
/* vim macro for easily updating set_thing
0v0wwv$hs[thing_idx.p€kbidx] = thing.Ithing_pool.lyiw$p
*/
	thing_pool.pos[thing_idx.idx] = thing.pos
  thing_pool.level[thing_idx.idx] = thing.level
  thing_pool.draw_thing[thing_idx.idx] = thing.draw_thing
}
fast_dot :: proc(level: Level) -> Thing {
	return {pos = level_center(level), 
    level = level,
    draw_thing = proc(thing_idx: ThingIdx, camera: Camera) {
      raylib.DrawCircleV(transform_to_camera(get.pos, camera), 1. * camera.zoom, raylib.BLUE)
		}
  }
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
setup_game :: proc() -> (level: Level, camera: Camera) {
	// setup level
	level.size = {121, 50}
	level.data = make([]TileKind, level.size.x * level.size.y)
	// checker
	for tile, idx in level.data {
		level.data[idx] = TileKind(idx % 2)
	}

	// setup camera
	camera = Camera {
		pos  = level_center(level),
		zoom = min(
			f32(raylib.GetRenderWidth()) / f32(level.size.x),
			f32(raylib.GetRenderHeight()) / f32(level.size.y),
		),
	}
	return level, camera
}

main :: proc() {
  lifelong: virtual.Arena
  virtual.arena_init_static(lifelong, 1 * mem.Megabyte)
  scratch: virtual.Arena
  virtual.arena_init_static(scratch, 1 * mem.Megabyte)
  frame: virtual.Arena
  virtual.arena_init_static(frame, 1 * mem.Megabyte)


	setup_rendering()
	level, camera := setup_game()


  // game stuff
  for !raylib.WindowShouldClose() {
    // game loop
		// rendering (TODO) section this off into a different loop
  	raylib.BeginDrawing()
  	raylib.ClearBackground(raylib.LIGHTGRAY)
  	draw_level(level, camera)
		raylib.EndDrawing()
	}
	raylib.CloseWindow()
}
