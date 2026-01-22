package main
import "core:fmt"
import "vendor:raylib"

main :: proc() {
  raylib.InitWindow(1024, 1024, "Quicky");
  raylib.SetTargetFPS(60);
  for !raylib.WindowShouldClose() {
    raylib.BeginDrawing();
      raylib.ClearBackground(raylib.RAYWHITE);
    raylib.EndDrawing();
  }
  raylib.CloseWindow();
}
